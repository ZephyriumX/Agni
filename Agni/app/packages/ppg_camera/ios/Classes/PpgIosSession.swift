import AVFoundation
import Flutter

/// One AVFoundation capture session. Per frame it produces
///   [presentation_timestamp_s, R, G, B, fracSaturated, fracDark]   (means over the centre 50 % ROI)
/// using CMSampleBuffer presentation timestamps (host clock, monotonic), so the backend can verify real
/// frame timing exactly as on Android. The torch is on, focus and white balance are locked, and when the
/// device supports custom exposure a small ISO controller keeps mean-R in a non-saturated band.
final class PpgIosSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "agni.ppg_camera.video")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let emit: ([String: Any]) -> Void

    private var manual = false
    private var locked = false
    private var closed = false
    private var iso: Float = 100
    private var isoMin: Float = 50
    private var isoMax: Float = 1600
    private var expDuration = CMTime(value: 1, timescale: 125)
    private var framesSinceIso = 0
    private var buf: [Double] = []
    private var lastFlush = DispatchTime.now().uptimeNanoseconds
    private var frameDurationNs = 0

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
        super.init()
    }

    func setLocked(_ l: Bool) { queue.async { self.locked = l } }

    func start(targetFps: Int, minFps: Int, cameraKey: String?,
               onOk: @escaping ([String: Any]) -> Void, onErr: @escaping (String, String) -> Void) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            onErr("NO_PERMISSION", "Camera permission not granted")
            return
        }
        let cams = PpgCameraCaps.enumerate()
        guard let pick = PpgCameraCaps.choose(cams, targetFps: targetFps, minFps: minFps, preferredKey: cameraKey) else {
            if let k = cameraKey {
                if let sel = cams.first(where: { $0.key == k }) {
                    onErr("CAMERA_UNSUITABLE", "\(sel.label): \(PpgCameraCaps.reason(sel, minFps: minFps)). Choose another camera or Automatic.")
                } else {
                    onErr("CAMERA_UNSUITABLE", "The selected camera is not available on this iPhone. Choose another camera or Automatic.")
                }
            } else {
                onErr("FPS_UNSUPPORTED", "No back camera with a torch can stream at >= \(minFps) fps to apps on this device")
            }
            return
        }
        let dev = pick.cam.device
        device = dev
        manual = pick.cam.manual

        queue.async {
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                self.session.beginConfiguration()
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { onErr("OPEN_FAILED", "The camera input could not be added (is another app using it?)") }
                    return
                }
                self.session.addInput(input)
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true   // drops show up in the timestamps and are judged there
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { onErr("SESSION_FAILED", "The video output could not be added") }
                    return
                }
                self.session.addOutput(self.output)
                self.session.commitConfiguration()

                // Configure the device AFTER the input is attached, otherwise the session preset can override the format.
                try dev.lockForConfiguration()
                dev.activeFormat = pick.format
                let fps = min(Double(targetFps), pick.maxFps)
                let dur = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                self.frameDurationNs = Int(CMTimeGetSeconds(dur) * 1e9)
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
                if self.manual {
                    self.isoMin = pick.format.minISO
                    self.isoMax = min(pick.format.maxISO, 1600)
                    self.iso = max(self.isoMin, min(200, self.isoMax))
                    var d = CMTime(value: 1, timescale: 125)
                    if CMTimeCompare(d, pick.format.minExposureDuration) < 0 { d = pick.format.minExposureDuration }
                    if CMTimeCompare(d, pick.format.maxExposureDuration) > 0 { d = pick.format.maxExposureDuration }
                    if CMTimeCompare(d, dur) > 0 { d = dur }
                    self.expDuration = d
                    dev.setExposureModeCustom(duration: d, iso: self.iso, completionHandler: nil)
                }
                var torchError: Error?
                if dev.hasTorch && dev.isTorchModeSupported(.on) {
                    do { try dev.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } catch { torchError = error }
                }
                dev.unlockForConfiguration()
                if let te = torchError {
                    // No light means no pulse signal: fail clearly instead of recording darkness.
                    self.output.setSampleBufferDelegate(nil, queue: nil)
                    DispatchQueue.main.async {
                        onErr("OPEN_FAILED", "The torch could not be turned on (\(te.localizedDescription)). Let the phone cool down and retry.")
                    }
                    return
                }

                self.session.startRunning()
                let info: [String: Any] = [
                    "cameraId": pick.cam.key, "cameraKey": pick.cam.key, "cameraLabel": pick.cam.label,
                    "logicalId": pick.cam.key, "physicalId": NSNull(), "flash": pick.cam.hasFlash,
                    "width": pick.width, "height": pick.height, "streamMaxFps": pick.maxFps,
                    "manualExposure": self.manual, "targetFps": targetFps, "minFps": minFps, "platform": "ios",
                ]
                DispatchQueue.main.async { onOk(info) }
            } catch {
                DispatchQueue.main.async { onErr("OPEN_FAILED", "\(error.localizedDescription)") }
            }
        }
    }

    // MARK: - frames
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if closed { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let s = roiStats(pixels)
        buf.append(ts); buf.append(s[0]); buf.append(s[1]); buf.append(s[2]); buf.append(s[3]); buf.append(s[4])
        if manual && !locked { adaptIso(red: s[0], green: s[1]) }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastFlush > 100_000_000 || buf.count >= 6 * 12 { flush(now) }
    }

    private func flush(_ now: UInt64) {
        lastFlush = now
        let arr = buf
        buf.removeAll(keepingCapacity: true)
        let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
        let dev = device
        let expNs = Int((dev.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0) * 1e9)
        let batch: [String: Any] = [
            "frames": FlutterStandardTypedData(float64: data),
            "exposureNs": expNs, "iso": Int(dev?.iso ?? 0), "frameDurationNs": frameDurationNs,
            "manual": manual, "locked": locked,
        ]
        emit(batch)
    }

    /// Keep mean-R in [140,205] while a finger-like (red-dominant) image is present.
    private func adaptIso(red: Double, green: Double) {
        framesSinceIso += 1
        if framesSinceIso < 6 { return }
        framesSinceIso = 0
        let fingerLike = red > 40 && red > 1.3 * green
        if !fingerLike || (red >= 140 && red <= 205) { return }
        let factor = min(1.6, max(0.5, pow(172.0 / max(red, 1.0), 0.7)))
        let next = Float(min(Double(isoMax), max(Double(isoMin), Double(iso) * factor)))
        if abs(next - iso) < 1 { return }
        iso = next
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            dev.setExposureModeCustom(duration: expDuration, iso: iso, completionHandler: nil)
            dev.unlockForConfiguration()
        } catch {}
    }

    /// Means (R, G, B in 0..255) + saturated/dark pixel fractions over the central 50 % ROI of a BGRA buffer.
    private func roiStats(_ pb: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [0, 0, 0, 0, 0] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sr = 0.0, sg = 0.0, sb = 0.0
        var hi = 0, lo = 0, n = 0
        var y = h / 4
        while y < h * 3 / 4 {
            var x = w / 4
            while x < w * 3 / 4 {
                let o = y * stride + x * 4          // BGRA
                let b = Double(p[o]), g = Double(p[o + 1]), r = Double(p[o + 2])
                sr += r; sg += g; sb += b
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if luma >= 250 { hi += 1 } else if luma <= 5 { lo += 1 }
                n += 1
                x += 2
            }
            y += 2
        }
        if n == 0 { return [0, 0, 0, 0, 0] }
        let d = Double(n)
        return [sr / d, sg / d, sb / d, Double(hi) / d, Double(lo) / d]
    }

    // MARK: - teardown
    /// Safe to call more than once. Turns the torch off and releases the camera.
    func stop() {
        if closed { return }
        closed = true
        let dev = device
        queue.async {
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            for o in self.session.outputs { self.session.removeOutput(o) }
            self.session.commitConfiguration()
            if let d = dev {
                do {
                    try d.lockForConfiguration()
                    if d.hasTorch && d.torchMode != .off { d.torchMode = .off }
                    d.unlockForConfiguration()
                } catch {}
            }
        }
    }
}
