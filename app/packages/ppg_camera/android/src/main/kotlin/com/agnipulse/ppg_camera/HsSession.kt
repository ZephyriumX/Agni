package com.agnipulse.ppg_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Range
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * High-speed capture path for phones whose regular YUV stream is capped (e.g. 30 fps) but whose
 * camera offers CONSTRAINED HIGH-SPEED sessions (e.g. [60,120] / [120,120]).
 *
 * A constrained high-speed session only accepts preview/video-type surfaces, never an ImageReader,
 * so frames go to a SurfaceTexture (external OES texture). A fragment shader averages a 32x32 grid
 * of taps over the centre 50 % ROI into a 2x1 FLOAT framebuffer:
 *      pixel 0 = mean R,G,B (0..255)       pixel 1 = (fraction saturated, fraction dark)
 * A float target is mandatory: an 8-bit target would quantise the sub-level pulse away. If the GPU
 * cannot render to float we FAIL with HS_GL_UNSUPPORTED rather than degrade silently.
 *
 * Output batches are identical to [PpgSession] (stride 6, sensor timestamps), so the backend and the
 * timing validator are unchanged. Frames the pipeline cannot keep up with show up as timestamp gaps
 * and are judged by the validator, never hidden.
 *
 * Exposure: manual exposure is not offered in high-speed mode; auto-exposure runs and is LOCKED
 * (AE+AWB lock) when the app calls setLocked(true). Everything is logged in [diag] for support.
 */
class HsSession(
    private val ctx: Context,
    private val targetFps: Int,
    private val minFps: Int,
    private val emit: (Map<String, Any?>) -> Unit,
) : CaptureSession {
    private val thread = HandlerThread("ppg-hs").also { it.start() }
    private val bg = Handler(thread.looper)
    private val t0 = SystemClock.elapsedRealtime()
    private val log = java.util.Collections.synchronizedList(ArrayList<String>())

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var pick: CameraCaps.Pick? = null
    private var candidates: List<CameraCaps.Hs> = emptyList()
    private var candIdx = 0
    private var level = 0                       // request-key level, see buildRequests()
    private var range: CameraCaps.Hs? = null
    private var onOk: ((Map<String, Any?>) -> Unit)? = null
    private var onErr: ((String, String) -> Unit)? = null
    private var reported = false
    @Volatile private var closed = false
    @Volatile private var locked = false

    // GL
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var oesTex = 0
    private var fboTex = 0
    private var fbo = 0
    private var prog = 0
    private var posBuf: FloatBuffer? = null
    private var st: SurfaceTexture? = null
    private var surface: Surface? = null
    private var readBuf: FloatBuffer? = null
    private var precision = "none"

    // frames
    private var lastTs = 0L
    private var nFrames = 0
    private var nDup = 0
    private val buf = ArrayList<Double>(6 * 40)
    private var lastFlush = 0L
    @Volatile private var lastExpNs = 0L
    @Volatile private var lastIso = 0
    @Volatile private var lastFrameNs = 0L

    override fun diag(): List<String> = synchronized(log) { ArrayList(log) }
    private fun d(msg: String) { log.add("+${SystemClock.elapsedRealtime() - t0}ms $msg") }

    @SuppressLint("MissingPermission")
    fun start(p: CameraCaps.Pick, ok: (Map<String, Any?>) -> Unit, err: (String, String) -> Unit) {
        pick = p; onOk = ok; onErr = err
        candidates = p.hsCandidates.ifEmpty { listOf(CameraCaps.Hs(minFps, minFps, p.width, p.height)) }
        d("high-speed start camera=${p.cam.key} candidates=${candidates.joinToString { "[${it.lo},${it.hi}]@${it.w}x${it.h}" }}")
        bg.post {
            try {
                initGl()
                openCamera()
            } catch (e: Exception) {
                fail("HS_GL_UNSUPPORTED", "GPU setup failed: ${e.message}")
            }
        }
    }

    private fun fail(code: String, msg: String) {
        d("FAIL $code: $msg")
        if (!reported) { reported = true; onErr?.invoke(code, msg + " | " + diag().takeLast(8).joinToString(" ; ")) }
        stop()
    }

    // ------------------------------------------------------------------ GL
    private fun initGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val v = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, v, 0, v, 1)) { "eglInitialize failed" }
        val cfgAttr = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, 0x40 /* EGL_OPENGL_ES3_BIT_KHR */,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE)
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(eglDisplay, cfgAttr, 0, cfgs, 0, 1, n, 0) && n[0] > 0) { "no ES3 EGL config" }
        eglContext = EGL14.eglCreateContext(eglDisplay, cfgs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "no ES3 context" }
        eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, cfgs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "no pbuffer" }
        check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) { "eglMakeCurrent failed" }
        val ext = GLES20.glGetString(GLES20.GL_EXTENSIONS) ?: ""
        d("GL ${GLES20.glGetString(GLES20.GL_RENDERER)} / ${GLES20.glGetString(GLES20.GL_VERSION)}; float-render=${ext.contains("GL_EXT_color_buffer_float")}; oes-essl3=${ext.contains("GL_OES_EGL_image_external_essl3")}")

        // float render target (RGBA32F, then RGBA16F)
        val tex = IntArray(1); GLES20.glGenTextures(1, tex, 0); fboTex = tex[0]
        val fb = IntArray(1); GLES20.glGenFramebuffers(1, fb, 0); fbo = fb[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        for ((fmt, name) in listOf(GLES30.GL_RGBA32F to "float32", GLES30.GL_RGBA16F to "float16")) {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, fmt, 2, 1, 0, GLES20.GL_RGBA, GLES20.GL_FLOAT, null)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, fboTex, 0)
            if (GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) == GLES20.GL_FRAMEBUFFER_COMPLETE) { precision = name; break }
        }
        check(precision != "none") { "GPU cannot render to a float texture (needs GL_EXT_color_buffer_float)" }
        d("render target precision=$precision")

        val vs = "#version 300 es\nin vec4 aPos;\nvoid main(){ gl_Position = aPos; }\n"
        val fs = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES uTex;
out vec4 o;
void main(){
  vec3 sum = vec3(0.0); float hi = 0.0; float lo = 0.0;
  for (int j = 0; j < 32; j++) {
    for (int i = 0; i < 32; i++) {
      vec2 uv = vec2(0.25 + 0.5 * (float(i) + 0.5) / 32.0, 0.25 + 0.5 * (float(j) + 0.5) / 32.0);
      vec3 c = texture(uTex, uv).rgb;
      sum += c;
      float y = dot(c, vec3(0.299, 0.587, 0.114));
      hi += step(250.0 / 255.0, y);
      lo += 1.0 - step(5.0 / 255.0 + 0.0001, y);
    }
  }
  if (gl_FragCoord.x < 1.0) o = vec4(sum * (255.0 / 1024.0), 1.0);
  else o = vec4(hi / 1024.0, lo / 1024.0, 0.0, 1.0);
}
"""
        prog = link(vs, fs)
        posBuf = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            .apply { put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0) }
        readBuf = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

        val ot = IntArray(1); GLES20.glGenTextures(1, ot, 0); oesTex = ot[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        val s = SurfaceTexture(oesTex)
        s.setDefaultBufferSize(pick!!.width, pick!!.height)
        s.setOnFrameAvailableListener({ onFrame() }, bg)
        st = s
        surface = Surface(s)
        d("SurfaceTexture ready")
    }

    private fun link(vs: String, fs: String): Int {
        fun sh(type: Int, src: String): Int {
            val id = GLES20.glCreateShader(type)
            GLES20.glShaderSource(id, src); GLES20.glCompileShader(id)
            val ok = IntArray(1); GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader compile: ${GLES20.glGetShaderInfoLog(id)}" }
            return id
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, sh(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, sh(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        val ok = IntArray(1); GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "program link: ${GLES20.glGetProgramInfoLog(p)}" }
        return p
    }

    /** One frame: latch it, reduce it on the GPU, read 2 float pixels, queue [t,R,G,B,sat,dark]. */
    private fun onFrame() {
        if (closed) return
        val s = st ?: return
        try {
            s.updateTexImage()
            val ts = s.timestamp                       // sensor timestamp, ns (same clock as Image.timestamp)
            if (ts <= 0L) return
            if (ts == lastTs) { nDup++; return }
            lastTs = ts
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, 2, 1)
            GLES20.glUseProgram(prog)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(prog, "uTex"), 0)
            val loc = GLES20.glGetAttribLocation(prog, "aPos")
            GLES20.glEnableVertexAttribArray(loc)
            GLES20.glVertexAttribPointer(loc, 2, GLES20.GL_FLOAT, false, 0, posBuf)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            val rb = readBuf!!; rb.position(0)
            GLES20.glReadPixels(0, 0, 2, 1, GLES20.GL_RGBA, GLES20.GL_FLOAT, rb)
            val err = GLES20.glGetError()
            if (err != GLES20.GL_NO_ERROR) { if (nFrames == 0) d("GL error 0x${Integer.toHexString(err)} on first frame"); return }
            nFrames++
            if (nFrames == 1) d("first frame ts=${ts}ns mean=(${rb.get(0)},${rb.get(1)},${rb.get(2)})")
            buf.add(ts / 1e9); buf.add(rb.get(0).toDouble()); buf.add(rb.get(1).toDouble()); buf.add(rb.get(2).toDouble())
            buf.add(rb.get(4).toDouble()); buf.add(rb.get(5).toDouble())
            val now = System.nanoTime()
            if (now - lastFlush > 100_000_000L || buf.size >= 6 * 24) flush(now)
        } catch (e: Exception) {
            d("frame error: ${e.message}")
        }
    }

    private fun flush(now: Long) {
        lastFlush = now
        val arr = DoubleArray(buf.size) { buf[it] }
        buf.clear()
        emit(mapOf("frames" to arr, "exposureNs" to lastExpNs, "iso" to lastIso, "frameDurationNs" to lastFrameNs,
            "manual" to false, "locked" to locked))
    }

    // ------------------------------------------------------------------ camera
    @SuppressLint("MissingPermission")
    private fun openCamera() {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        mgr.openCamera(pick!!.cam.logicalId, object : CameraDevice.StateCallback() {
            override fun onOpened(cd: CameraDevice) {
                device = cd; d("camera opened")
                try { configure() } catch (e: Exception) { fail("SESSION_FAILED", e.message ?: "configure") }
            }
            override fun onDisconnected(cd: CameraDevice) { d("camera disconnected"); stop() }
            override fun onError(cd: CameraDevice, error: Int) {
                fail(if (error == CameraDevice.StateCallback.ERROR_CAMERA_IN_USE) "CAMERA_IN_USE" else "OPEN_FAILED", "Camera2 error $error")
            }
        }, bg)
    }

    @Suppress("DEPRECATION")
    private fun configure() {
        val cd = device ?: return
        val r = candidates[candIdx]
        range = r
        st?.setDefaultBufferSize(r.w, r.h)
        d("createConstrainedHighSpeedCaptureSession [${r.lo},${r.hi}] ${r.w}x${r.h}")
        cd.createConstrainedHighSpeedCaptureSession(listOf(surface!!), object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                if (closed) { s.close(); return }
                session = s
                d("session configured")
                if (!startRepeating(s)) return
            }
            override fun onConfigureFailed(s: CameraCaptureSession) {
                d("configure failed for [${r.lo},${r.hi}]")
                if (candIdx + 1 < candidates.size) { candIdx++; try { configure() } catch (e: Exception) { fail("SESSION_FAILED", e.message ?: "") } }
                else fail("SESSION_FAILED", "high-speed session could not be configured for any range >= $minFps fps")
            }
        }, bg)
    }

    /**
     * Request keys are added in levels because some drivers reject extra keys in high-speed bursts:
     * 0 = torch + AF off + stabilisation off (+ AE/AWB lock when locked), 1 = torch only, 2 = fps range only.
     */
    private fun startRepeating(s: CameraCaptureSession): Boolean {
        val hs = s as CameraConstrainedHighSpeedCaptureSession
        val cd = device ?: return false
        val r = range ?: return false
        while (level <= 2) {
            try {
                val b = cd.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                b.addTarget(surface!!)
                b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(r.lo, r.hi))
                if (level <= 1) b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
                if (level == 0) {
                    b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                    b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
                    if (locked) { b.set(CaptureRequest.CONTROL_AE_LOCK, true); b.set(CaptureRequest.CONTROL_AWB_LOCK, true) }
                }
                val list = hs.createHighSpeedRequestList(b.build())
                hs.setRepeatingBurst(list, object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                        result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { lastExpNs = it }
                        result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { lastIso = it }
                        result.get(CaptureResult.SENSOR_FRAME_DURATION)?.let { lastFrameNs = it }
                    }
                }, bg)
                d("repeating burst started, request level=$level, batch=${list.size}")
                if (level > 0) tryTorchFallback()
                reportOk(r)
                return true
            } catch (e: Exception) {
                d("request level $level rejected: ${e.javaClass.simpleName} ${e.message}")
                level++
            }
        }
        fail("SESSION_FAILED", "the camera rejected every high-speed request variant")
        return false
    }

    private fun tryTorchFallback() {
        try {
            (ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager).setTorchMode(pick!!.cam.logicalId, true)
            d("torch via CameraManager.setTorchMode")
        } catch (e: Exception) { d("setTorchMode failed: ${e.message}") }
    }

    private fun reportOk(r: CameraCaps.Hs) {
        if (reported) return
        reported = true
        val p = pick!!
        onOk?.invoke(mapOf("cameraId" to p.cam.key, "cameraKey" to p.cam.key, "cameraLabel" to p.cam.label,
            "logicalId" to p.cam.logicalId, "physicalId" to p.cam.physicalId, "flash" to p.cam.hasFlash,
            "width" to r.w, "height" to r.h, "streamMaxFps" to r.hi, "manualExposure" to false,
            "targetFps" to targetFps, "minFps" to minFps, "platform" to "android",
            "mode" to "highspeed", "hsRange" to listOf(r.lo, r.hi), "precision" to precision,
            "diag" to diag()))
    }

    override fun setLocked(l: Boolean) {
        locked = l
        bg.post {
            val s = session ?: return@post
            if (closed || level != 0) { d("lock requested; AE/AWB lock unavailable at request level $level"); return@post }
            try { startRepeating(s); d("exposure lock=$l") } catch (e: Exception) { d("lock failed: ${e.message}") }
        }
    }

    override fun stop() {
        if (closed) return
        closed = true
        bg.post {
            d("stop: frames=$nFrames dup=$nDup")
            try { session?.stopRepeating() } catch (_: Exception) {}
            try { session?.close() } catch (_: Exception) {}
            try { device?.close() } catch (_: Exception) {}
            try { st?.release() } catch (_: Exception) {}
            try { surface?.release() } catch (_: Exception) {}
            try {
                if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                    if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                    if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                    EGL14.eglTerminate(eglDisplay)
                }
            } catch (_: Exception) {}
            thread.quitSafely()
        }
    }
}
