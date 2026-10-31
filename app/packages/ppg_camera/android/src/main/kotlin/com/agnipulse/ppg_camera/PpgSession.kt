package com.agnipulse.ppg_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * One Camera2 capture session producing, per frame:
 *   [sensor_timestamp_s, R, G, B, fracSaturated, fracDark]   (means over the centre ROI)
 * Sensor timestamps (not arrival time) are used so the backend can verify real frame timing.
 *
 * Exposure: when MANUAL_SENSOR is available we fix exposure time (~1/125 s) and frame duration
 * (1/fps) and run a tiny ISO controller keeping mean-R in a non-saturated band while a finger is
 * present. Auto-exposure would otherwise brighten the (dark, red) finger image until R clips and
 * the pulse disappears. setLocked(true) freezes ISO for the measurement.
 */
class PpgSession(
    private val ctx: Context,
    private val targetFps: Int,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val thread = HandlerThread("ppg-camera").also { it.start() }
    private val bg = Handler(thread.looper)
    private var device: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var builder: CaptureRequest.Builder? = null
    private var manual = false
    @Volatile private var locked = false
    private var closed = false

    private var iso = 200
    private var isoMin = 50
    private var isoMax = 1600
    private var expNs = 8_000_000L
    private var frameNs = (1e9 / targetFps).toLong()
    @Volatile private var lastExpNs = 0L
    @Volatile private var lastIso = 0
    @Volatile private var lastFrameNs = 0L

    private val buf = ArrayList<Double>(6 * 16)
    private var lastFlush = 0L
    private var framesSinceIso = 0

    @SuppressLint("MissingPermission")
    fun start(onOk: (Map<String, Any?>) -> Unit, onErr: (String, String) -> Unit) {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val pick = CameraCaps.pick(ctx, targetFps)
        if (pick == null) {
            onErr("FPS_UNSUPPORTED", "No back camera with flash can stream YUV at >= $targetFps fps on this device")
            return
        }
        val ch = mgr.getCameraCharacteristics(pick.id)
        manual = pick.manual
        ch.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.let { isoMin = it.lower; isoMax = min(it.upper, 1600) }
        ch.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)?.let {
            expNs = expNs.coerceIn(it.lower, max(it.lower, min(it.upper, frameNs - 1_000_000L)))
        }
        iso = max(isoMin, 200).coerceAtMost(isoMax)

        reader = ImageReader.newInstance(pick.width, pick.height, ImageFormat.YUV_420_888, 4).also {
            it.setOnImageAvailableListener({ r -> onImage(r) }, bg)
        }
        try {
            mgr.openCamera(pick.id, object : CameraDevice.StateCallback() {
                override fun onOpened(cd: CameraDevice) {
                    device = cd
                    try { createSession(cd, ch, pick, onOk, onErr) } catch (e: Exception) { onErr("SESSION_FAILED", e.message ?: "") }
                }
                override fun onDisconnected(cd: CameraDevice) { stop() }
                override fun onError(cd: CameraDevice, error: Int) {
                    onErr(if (error == ERROR_CAMERA_IN_USE) "CAMERA_IN_USE" else "OPEN_FAILED", "Camera2 error $error"); stop()
                }
            }, bg)
        } catch (e: Exception) {
            onErr("OPEN_FAILED", e.message ?: "")
        }
    }

    @Suppress("DEPRECATION")
    private fun createSession(cd: CameraDevice, ch: CameraCharacteristics, pick: CameraCaps.Pick,
                              onOk: (Map<String, Any?>) -> Unit, onErr: (String, String) -> Unit) {
        val b = cd.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        builder = b
        b.addTarget(reader!!.surface)
        b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
        b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
        b.set(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_OFF)
        b.set(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_OFF)
        b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
        b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF)
        b.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT)
        if (manual) {
            b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
            applyManual(b)
        } else {
            // Fallback: auto exposure with the tightest fps range reaching the target, lowest compensation
            val ranges = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()
            val r = ranges.filter { it.upper >= targetFps }
                .sortedWith(compareBy({ it.upper - it.lower }, { -it.lower })).firstOrNull()
            if (r != null) b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, r)
            ch.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)?.let {
                b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, it.lower)
            }
        }
        cd.createCaptureSession(listOf(reader!!.surface), object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                if (closed) { s.close(); return }
                captureSession = s
                s.setRepeatingRequest(b.build(), object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                        result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { lastExpNs = it }
                        result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { lastIso = it }
                        result.get(CaptureResult.SENSOR_FRAME_DURATION)?.let { lastFrameNs = it }
                    }
                }, bg)
                onOk(mapOf("cameraId" to pick.id, "width" to pick.width, "height" to pick.height,
                    "streamMaxFps" to pick.maxFps, "manualExposure" to manual, "targetFps" to targetFps))
            }
            override fun onConfigureFailed(s: CameraCaptureSession) { onErr("SESSION_FAILED", "configure failed") }
        }, bg)
    }

    private fun applyManual(b: CaptureRequest.Builder) {
        b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, expNs)
        b.set(CaptureRequest.SENSOR_SENSITIVITY, iso)
        b.set(CaptureRequest.SENSOR_FRAME_DURATION, frameNs)
    }

    fun setLocked(l: Boolean) { locked = l }

    private fun onImage(r: ImageReader) {
        val img = try { r.acquireNextImage() } catch (e: Exception) { null } ?: return
        try {
            val ts = img.timestamp / 1e9
            val s = roiStats(img)
            buf.add(ts); buf.add(s[0]); buf.add(s[1]); buf.add(s[2]); buf.add(s[3]); buf.add(s[4])
            if (manual && !locked) adaptIso(s[0], s[1])
            val now = System.nanoTime()
            if (now - lastFlush > 100_000_000L || buf.size >= 6 * 12) flush(now)
        } finally { img.close() }
    }

    private fun flush(now: Long) {
        lastFlush = now
        val arr = DoubleArray(buf.size) { buf[it] }
        buf.clear()
        emit(mapOf("frames" to arr, "exposureNs" to lastExpNs, "iso" to lastIso, "frameDurationNs" to lastFrameNs,
            "manual" to manual, "locked" to locked))
    }

    /** Keep mean-R in [140,205] while a finger-like (red-dominant) image is present. */
    private fun adaptIso(red: Double, green: Double) {
        if (++framesSinceIso < 6) return
        framesSinceIso = 0
        val fingerLike = red > 40 && red > 1.3 * green
        if (!fingerLike || (red in 140.0..205.0)) return
        val target = 172.0
        val factor = (target / max(red, 1.0)).pow(0.7).coerceIn(0.5, 1.6)
        val next = (iso * factor).toInt().coerceIn(isoMin, isoMax)
        if (next != iso) {
            iso = next
            builder?.let { b ->
                b.set(CaptureRequest.SENSOR_SENSITIVITY, iso)
                try { captureSession?.setRepeatingRequest(b.build(), null, bg) } catch (_: Exception) {}
            }
        }
    }

    /** Means (R,G,B in 0..255) + saturated/dark pixel fractions over the central 50% ROI. */
    private fun roiStats(img: Image): DoubleArray {
        val w = img.width; val h = img.height
        val yp = img.planes[0]; val up = img.planes[1]; val vp = img.planes[2]
        val yb = yp.buffer; val ub = up.buffer; val vb = vp.buffer
        var sy = 0.0; var su = 0.0; var sv = 0.0; var hi = 0; var lo = 0; var n = 0
        val x0 = w / 4; val x1 = w * 3 / 4; val y0 = h / 4; val y1 = h * 3 / 4
        var y = y0
        while (y < y1) {
            var x = x0
            while (x < x1) {
                val yy = yb.get(y * yp.rowStride + x * yp.pixelStride).toInt() and 0xFF
                val ui = (y shr 1) * up.rowStride + (x shr 1) * up.pixelStride
                val vi = (y shr 1) * vp.rowStride + (x shr 1) * vp.pixelStride
                sy += yy; su += (ub.get(ui).toInt() and 0xFF); sv += (vb.get(vi).toInt() and 0xFF)
                if (yy >= 250) hi++ else if (yy <= 5) lo++
                n++; x += 2
            }
            y += 2
        }
        if (n == 0) return doubleArrayOf(0.0, 0.0, 0.0, 0.0, 0.0)
        val Y = sy / n; val U = su / n - 128.0; val V = sv / n - 128.0
        val r = (Y + 1.402 * V).coerceIn(0.0, 255.0)
        val g = (Y - 0.344136 * U - 0.714136 * V).coerceIn(0.0, 255.0)
        val bl = (Y + 1.772 * U).coerceIn(0.0, 255.0)
        return doubleArrayOf(r, g, bl, hi.toDouble() / n, lo.toDouble() / n)
    }

    fun stop() {
        if (closed) return
        closed = true
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        thread.quitSafely()
    }
}
