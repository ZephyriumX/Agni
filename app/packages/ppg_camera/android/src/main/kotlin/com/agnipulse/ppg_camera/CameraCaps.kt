package com.agnipulse.ppg_camera

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata

/** Reports what each back camera can REALLY do, so the app can fail with evidence instead of guessing. */
object CameraCaps {
    data class Pick(val id: String, val width: Int, val height: Int, val maxFps: Double, val manual: Boolean)

    private fun yuvSizes(ch: CameraCharacteristics): List<Triple<Int, Int, Double>> {
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        return map.getOutputSizes(ImageFormat.YUV_420_888).orEmpty().map { s ->
            val dur = map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, s)  // ns
            Triple(s.width, s.height, if (dur > 0) 1e9 / dur else 0.0)
        }
    }

    fun hasManual(ch: CameraCharacteristics): Boolean =
        ch.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) == true

    /** Smallest YUV size (>=160 px wide) that can stream at >= fps, preferring a camera with manual sensor control. */
    fun pick(ctx: Context, fps: Int): Pick? {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        var best: Pick? = null
        for (id in mgr.cameraIdList.sortedBy { it.toIntOrNull() ?: 99 }) {
            val ch = mgr.getCameraCharacteristics(id)
            if (ch.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) continue
            if (ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) != true) continue
            val size = yuvSizes(ch).filter { it.first >= 160 && it.third >= fps - 0.5 }
                .minByOrNull { it.first * it.second } ?: continue
            val cand = Pick(id, size.first, size.second, size.third, hasManual(ch))
            if (best == null || (cand.manual && !best.manual)) best = cand
            if (best != null && best.manual) break
        }
        return best
    }

    fun query(ctx: Context): Map<String, Any?> {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cams = ArrayList<Map<String, Any?>>()
        for (id in mgr.cameraIdList) {
            val ch = mgr.getCameraCharacteristics(id)
            if (ch.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) continue
            val ranges = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.map { listOf(it.lower, it.upper) } ?: emptyList()
            val sizes = yuvSizes(ch).sortedBy { it.first * it.second }.take(6)
                .map { mapOf("w" to it.first, "h" to it.second, "maxFps" to it.third) }
            val maxYuvFps = yuvSizes(ch).maxOfOrNull { it.third } ?: 0.0
            cams.add(mapOf(
                "id" to id,
                "hasFlash" to (ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true),
                "hardwareLevel" to ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL),
                "manualSensor" to hasManual(ch),
                "aeFpsRanges" to ranges,
                "smallYuvSizes" to sizes,
                "maxYuvFps" to maxYuvFps))
        }
        val p = pick(ctx, 60)
        return mapOf("cameras" to cams, "supports60" to (p != null),
            "chosen" to p?.let { mapOf("id" to it.id, "w" to it.width, "h" to it.height, "maxFps" to it.maxFps,
                "manual" to it.manual) })
    }
}
