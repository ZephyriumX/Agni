package com.agnipulse.ppg_camera

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Reports what each BACK camera can REALLY do, so the app can fail with evidence instead of guessing.
 *
 * Phones with several rear lenses usually expose one *logical* camera in cameraIdList and hide the
 * individual lenses behind CameraCharacteristics.physicalCameraIds (API 28+). Earlier versions looked
 * only at cameraIdList, so they never saw the other lenses. This object lists both and lets the caller
 * pick one by [Cam.key]:
 *   "<id>"            a camera listed in cameraIdList (logical or single)
 *   "<id>:<physId>"   one physical lens behind logical camera <id> (opened via OutputConfiguration)
 */
object CameraCaps {
    data class Sz(val w: Int, val h: Int, val fps: Double)

    data class Cam(
        val key: String,
        val logicalId: String,
        val physicalId: String?,          // non-null: stream is routed to this physical lens
        val kind: String,                 // "single" | "logical" | "physical"
        val hasFlash: Boolean,            // torch belongs to the logical device, so physical lenses inherit it
        val manual: Boolean,
        val yuv: List<Sz>,                // YUV_420_888 sizes with their real max frame rate
        val surfaceMaxFps: Double,        // SurfaceTexture/video class streams (diagnostic only; no pixel access)
        val highSpeed: List<List<Int>>,   // constrained high-speed ranges (diagnostic only)
        val aeRanges: List<List<Int>>,
        val hardwareLevel: Int?,
        val focalMm: Double?,
        val equivMm: Double?,             // 35 mm-equivalent focal length, a hint for ultra-wide / main / tele
        val physicalIds: List<String>,    // for logical cameras: the lenses behind it
    ) {
        val maxFps: Double get() = yuv.maxOfOrNull { it.fps } ?: 0.0
        var label: String = key
    }

    data class Pick(val cam: Cam, val width: Int, val height: Int, val maxFps: Double) {
        val manual: Boolean get() = cam.manual
        val id: String get() = cam.logicalId
    }

    private fun yuvSizes(ch: CameraCharacteristics): List<Sz> {
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        return map.getOutputSizes(ImageFormat.YUV_420_888).orEmpty().map { s ->
            val dur = map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, s)  // ns
            Sz(s.width, s.height, if (dur > 0) 1e9 / dur else 0.0)
        }
    }

    private fun surfaceMaxFps(ch: CameraCharacteristics): Double {
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return 0.0
        return try {
            map.getOutputSizes(SurfaceTexture::class.java).orEmpty().maxOfOrNull { s ->
                val d = map.getOutputMinFrameDuration(SurfaceTexture::class.java, s)
                if (d > 0) 1e9 / d else 0.0
            } ?: 0.0
        } catch (_: Exception) { 0.0 }
    }

    private fun highSpeed(ch: CameraCharacteristics): List<List<Int>> = if (Build.VERSION.SDK_INT < 23) emptyList() else try {
        ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.highSpeedVideoFpsRanges
            ?.map { listOf(it.lower, it.upper) } ?: emptyList()
    } catch (_: Exception) { emptyList() }

    fun hasManual(ch: CameraCharacteristics): Boolean =
        ch.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) == true

    private fun physicalIdsOf(ch: CameraCharacteristics): List<String> =
        if (Build.VERSION.SDK_INT >= 28) {
            try { ch.physicalCameraIds.toList().sortedBy { it.toIntOrNull() ?: 99 } } catch (_: Exception) { emptyList() }
        } else emptyList()

    private fun build(key: String, logicalId: String, physicalId: String?, ch: CameraCharacteristics,
                      flash: Boolean, kind: String, physIds: List<String>): Cam {
        val focal = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()?.toDouble()
        val sensor = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val equiv = if (focal != null && sensor != null && sensor.width > 0f)
            focal * 43.27 / hypot(sensor.width.toDouble(), sensor.height.toDouble()) else null
        return Cam(
            key = key, logicalId = logicalId, physicalId = physicalId, kind = kind, hasFlash = flash,
            manual = hasManual(ch), yuv = yuvSizes(ch), surfaceMaxFps = surfaceMaxFps(ch),
            highSpeed = highSpeed(ch),
            aeRanges = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.map { listOf(it.lower, it.upper) } ?: emptyList(),
            hardwareLevel = ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL),
            focalMm = focal, equivMm = equiv, physicalIds = physIds)
    }

    private fun lensName(eq: Double?): String = when {
        eq == null -> "Rear camera"
        eq < 20 -> "Ultra-wide lens"
        eq <= 36 -> "Main lens"
        eq <= 75 -> "Telephoto lens"
        else -> "Long telephoto lens"
    }

    /** Result of [enumerate]: selectable lenses plus physical lenses Android refused to describe. */
    data class Listing(val cams: List<Cam>, val hiddenPhysical: List<String>)

    fun enumerate(ctx: Context): Listing {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val ids = try { mgr.cameraIdList.sortedBy { it.toIntOrNull() ?: 99 } } catch (_: Exception) { emptyList() }
        val back = LinkedHashMap<String, CameraCharacteristics>()
        for (id in ids) {
            val ch = try { mgr.getCameraCharacteristics(id) } catch (_: Exception) { continue }
            if (ch.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK) back[id] = ch
        }
        val out = ArrayList<Cam>()
        val hidden = ArrayList<String>()
        for ((id, ch) in back) {
            val phys = physicalIdsOf(ch)
            val flash = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            out.add(build(id, id, null, ch, flash, if (phys.isNotEmpty()) "logical" else "single", phys))
            for (pid in phys) {
                if (back.containsKey(pid)) continue          // already listed directly: no duplicate
                val pch = try { mgr.getCameraCharacteristics(pid) } catch (_: Exception) { null }
                if (pch == null) { hidden.add("$id:$pid"); continue }
                out.add(build("$id:$pid", id, pid, pch, flash, "physical", emptyList()))
            }
        }
        for (c in out) {
            val name = lensName(c.equivMm)
            val eq = c.equivMm?.let { " (~${it.roundToInt()} mm eq.)" } ?: ""
            c.label = when (c.kind) {
                "logical" -> "Rear camera ${c.logicalId} (combined, ${c.physicalIds.size} lenses)"
                else -> "$name$eq - camera ${c.key}"
            }
        }
        return Listing(out, hidden)
    }

    /** Smallest YUV size (>= 160 px wide) that reaches minFps on this camera, or null. Flash is required. */
    fun pickFor(c: Cam, minFps: Int): Pick? {
        if (!c.hasFlash) return null
        val s = c.yuv.filter { it.w >= 160 && it.fps >= minFps - 0.5 }.minByOrNull { it.w * it.h } ?: return null
        return Pick(c, s.w, s.h, s.fps)
    }

    /** Why a camera is (not) usable, in words for the UI. */
    fun reason(c: Cam, minFps: Int): String = when {
        !c.hasFlash -> "no flash/torch"
        c.maxFps < minFps - 0.5 -> "streams at most ${c.maxFps.roundToInt()} fps to apps (needs $minFps)"
        else -> "ok"
    }

    /**
     * Automatic choice: cameras that reach the target first, then (capped at target) higher fps, manual
     * sensor control, a lens closest to the main one (next to the flash), logical before physical.
     * With [preferredKey] the user's choice is honoured or null is returned: never switched silently.
     */
    fun choose(cams: List<Cam>, targetFps: Int, minFps: Int, preferredKey: String? = null): Pick? {
        val cands = cams.mapNotNull { pickFor(it, minFps) }
        if (preferredKey != null) return cands.firstOrNull { it.cam.key == preferredKey }
        return cands.maxWithOrNull(compareBy<Pick>(
            { it.maxFps >= targetFps - 0.5 },
            { (min(it.maxFps, targetFps.toDouble()) * 2).roundToInt() },
            { it.cam.manual },
            { -abs((it.cam.equivMm ?: 26.0) - 26.0) },
            { it.cam.physicalId == null },
        ))
    }

    /** Entry point used by PpgSession. minFps defaults to fps (strict, as in v0.3.0). */
    fun pick(ctx: Context, fps: Int, minFps: Int = fps, preferredKey: String? = null): Pick? =
        choose(enumerate(ctx).cams, fps, minFps, preferredKey)

    private fun camMap(c: Cam, targetFps: Int, minFps: Int): Map<String, Any?> = mapOf(
        "key" to c.key, "id" to c.key, "logicalId" to c.logicalId, "physicalId" to c.physicalId,
        "kind" to c.kind, "label" to c.label, "hasFlash" to c.hasFlash, "manualSensor" to c.manual,
        "maxYuvFps" to c.maxFps, "surfaceMaxFps" to c.surfaceMaxFps, "highSpeedFpsRanges" to c.highSpeed,
        "aeFpsRanges" to c.aeRanges, "hardwareLevel" to c.hardwareLevel,
        "focalMm" to c.focalMm, "equivMm" to c.equivMm, "physicalIds" to c.physicalIds,
        "smallYuvSizes" to c.yuv.sortedBy { it.w * it.h }.take(6).map { mapOf("w" to it.w, "h" to it.h, "maxFps" to it.fps) },
        "meetsTarget" to (c.hasFlash && c.maxFps >= targetFps - 0.5),
        "meetsMinimum" to (pickFor(c, minFps) != null),
        "reason" to reason(c, minFps))

    fun query(ctx: Context, targetFps: Int = 60, minFps: Int = targetFps, preferredKey: String? = null): Map<String, Any?> {
        val listing = enumerate(ctx)
        val auto = choose(listing.cams, targetFps, minFps)
        val chosen = if (preferredKey != null) choose(listing.cams, targetFps, minFps, preferredKey) else auto
        val unknownPreference = preferredKey != null && listing.cams.none { it.key == preferredKey }
        return mapOf(
            "platform" to "android", "androidSdk" to Build.VERSION.SDK_INT,
            "targetFps" to targetFps, "minFps" to minFps,
            "cameras" to listing.cams.map { camMap(it, targetFps, minFps) },
            "hiddenPhysicalIds" to listing.hiddenPhysical,
            "autoKey" to auto?.cam?.key,
            "requestedKey" to preferredKey,
            "requestedKeyUnknown" to unknownPreference,
            "anyMeetsMinimum" to (auto != null),
            "meetsMinimum" to (chosen != null),
            "meetsTarget" to (chosen != null && chosen.maxFps >= targetFps - 0.5),
            "supports60" to listing.cams.any { pickFor(it, 60) != null },   // legacy key
            "chosen" to chosen?.let { mapOf("key" to it.cam.key, "id" to it.cam.key, "label" to it.cam.label,
                "w" to it.width, "h" to it.height, "maxFps" to it.maxFps, "manual" to it.manual) })
    }
}
