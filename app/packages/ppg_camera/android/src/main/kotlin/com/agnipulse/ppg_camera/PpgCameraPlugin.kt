package com.agnipulse.ppg_camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> Camera2 bridge.
 *  MethodChannel  agni/ppg_camera         : capabilities, start, setExposureLock, stop
 *  EventChannel   agni/ppg_camera/frames  : batches of per-frame channel means
 */
class PpgCameraPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var ctx: Context
    private lateinit var method: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    private var session: PpgSession? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ctx = binding.applicationContext
        method = MethodChannel(binding.binaryMessenger, "agni/ppg_camera")
        events = EventChannel(binding.binaryMessenger, "agni/ppg_camera/frames")
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        session?.stop(); session = null
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> try {
                val tf = call.argument<Int>("targetFps") ?: 60
                result.success(CameraCaps.query(ctx, tf, call.argument<Int>("minFps") ?: tf))
            } catch (e: Exception) {
                result.error("CAPS_FAILED", e.message, null)
            }
            "start" -> {
                if (ctx.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                    result.error("NO_PERMISSION", "Camera permission not granted", null); return
                }
                session?.stop()
                val fps = call.argument<Int>("targetFps") ?: 60
                val s = PpgSession(ctx, fps, call.argument<Int>("minFps") ?: fps) { batch -> main.post { sink?.success(batch) } }
                session = s
                s.start({ info -> main.post { result.success(info) } },
                        { code, msg -> main.post { session = null; result.error(code, msg, null) } })
            }
            "setExposureLock" -> {
                session?.setLocked(call.argument<Boolean>("locked") ?: true)
                result.success(null)
            }
            "stop" -> { session?.stop(); session = null; result.success(null) }
            else -> result.notImplemented()
        }
    }
}
