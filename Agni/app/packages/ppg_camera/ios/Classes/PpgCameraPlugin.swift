import AVFoundation
import Flutter
import UIKit

/// Flutter <-> AVFoundation bridge. Same channels and payloads as the Android plugin:
///   MethodChannel  agni/ppg_camera         : capabilities, requestPermission, start, setExposureLock, stop
///   EventChannel   agni/ppg_camera/frames  : batches of per-frame channel means
public class PpgCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var session: PpgIosSession?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PpgCameraPlugin()
        let method = FlutterMethodChannel(name: "agni/ppg_camera", binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: "agni/ppg_camera/frames", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        events.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let targetFps = (args["targetFps"] as? Int) ?? 60
        let minFps = (args["minFps"] as? Int) ?? targetFps
        let cameraKey = args["cameraKey"] as? String
        switch call.method {
        case "capabilities":
            result(PpgCameraCaps.query(targetFps: targetFps, minFps: minFps, preferredKey: cameraKey))
        case "requestPermission":
            // Done natively so the app needs no permission_handler build flags on iOS.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: result(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { result(granted) } }
            default: result(false)   // denied or restricted: the user must enable it in Settings
            }
        case "start":
            session?.stop()
            let s = PpgIosSession { [weak self] batch in
                DispatchQueue.main.async { self?.sink?(batch) }
            }
            session = s
            s.start(targetFps: targetFps, minFps: minFps, cameraKey: cameraKey,
                    onOk: { info in result(info) },
                    onErr: { [weak self] code, msg in
                        self?.session = nil
                        result(FlutterError(code: code, message: msg, details: nil))
                    })
        case "setExposureLock":
            session?.setLocked((args["locked"] as? Bool) ?? true)
            result(nil)
        case "stop":
            session?.stop()
            session = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        session?.stop()
        session = nil
    }
}
