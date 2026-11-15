import AVFoundation

/// Camera discovery and selection for iOS. Mirrors CameraCaps.kt so the Flutter side is identical.
///
/// iPhones expose each back lens as its own AVCaptureDevice (wide, ultra-wide, telephoto). Virtual
/// multi-camera devices (dual / triple) are deliberately NOT listed: they may switch lenses mid-scan.
/// Nothing here assumes a particular iPhone model: every number comes from the device's own formats.
struct PpgCam {
    let key: String                  // AVCaptureDevice.uniqueID
    let device: AVCaptureDevice
    let label: String
    let hasFlash: Bool               // torch available right now
    let manual: Bool                 // custom exposure supported
    let maxFps: Double               // best rate over 4:2:0 formats an app can read
    let order: Int                   // 0 = main wide lens (preferred: it sits next to the torch)
}

struct PpgPick {
    let cam: PpgCam
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let maxFps: Double
}

enum PpgCameraCaps {
    static func isReadableFormat(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func maxRate(_ f: AVCaptureDevice.Format) -> Double {
        return f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    }

    static func dims(_ f: AVCaptureDevice.Format) -> (Int, Int) {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    private static func lensInfo(_ d: AVCaptureDevice) -> (String, Int) {
        if d.deviceType == .builtInWideAngleCamera { return ("Main (wide) camera", 0) }
        if d.deviceType == .builtInTelephotoCamera { return ("Telephoto camera", 2) }
        if #available(iOS 13.0, *), d.deviceType == .builtInUltraWideCamera { return ("Ultra-wide camera", 1) }
        return (d.localizedName, 3)
    }

    static func enumerate() -> [PpgCam] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInTelephotoCamera]
        if #available(iOS 13.0, *) { types.append(.builtInUltraWideCamera) }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        let cams: [PpgCam] = found.map { d in
            let (label, order) = lensInfo(d)
            let rate = d.formats.filter { isReadableFormat($0) }.map { maxRate($0) }.max() ?? 0
            return PpgCam(key: d.uniqueID, device: d, label: label,
                          hasFlash: d.hasTorch && d.isTorchModeSupported(.on),
                          manual: d.isExposureModeSupported(.custom), maxFps: rate, order: order)
        }
        return cams.sorted { $0.order < $1.order }
    }

    /// Smallest readable format (>= 160 px wide) reaching minFps on this camera. Torch is required.
    static func pickFor(_ c: PpgCam, minFps: Int) -> PpgPick? {
        if !c.hasFlash { return nil }
        let ok = c.device.formats.filter { f in
            let (w, _) = dims(f)
            return isReadableFormat(f) && w >= 160 && maxRate(f) >= Double(minFps) - 0.5
        }
        guard let f = ok.min(by: { a, b in
            let (aw, ah) = dims(a); let (bw, bh) = dims(b)
            return aw * ah < bw * bh
        }) else { return nil }
        let (w, h) = dims(f)
        return PpgPick(cam: c, format: f, width: w, height: h, maxFps: maxRate(f))
    }

    static func reason(_ c: PpgCam, minFps: Int) -> String {
        if !c.hasFlash { return "no torch on this lens" }
        if c.maxFps < Double(minFps) - 0.5 { return "streams at most \(Int(c.maxFps.rounded())) fps to apps (needs \(minFps))" }
        return "ok"
    }

    /// Automatic choice (same ranking as Android). With preferredKey the user's choice is honoured or nil is
    /// returned: it is never switched silently.
    static func choose(_ cams: [PpgCam], targetFps: Int, minFps: Int, preferredKey: String?) -> PpgPick? {
        let cands = cams.compactMap { pickFor($0, minFps: minFps) }
        if let k = preferredKey { return cands.first { $0.cam.key == k } }
        func score(_ p: PpgPick) -> (Int, Int, Int, Int) {
            let meets = p.maxFps >= Double(targetFps) - 0.5 ? 1 : 0
            let capped = Int((min(p.maxFps, Double(targetFps)) * 2).rounded())
            return (meets, capped, p.cam.manual ? 1 : 0, -p.cam.order)
        }
        return cands.max { a, b in
            let x = score(a), y = score(b)
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            if x.2 != y.2 { return x.2 < y.2 }
            return x.3 < y.3
        }
    }

    static func query(targetFps: Int, minFps: Int, preferredKey: String?) -> [String: Any] {
        let cams = enumerate()
        let auto = choose(cams, targetFps: targetFps, minFps: minFps, preferredKey: nil)
        let chosen = preferredKey != nil
            ? choose(cams, targetFps: targetFps, minFps: minFps, preferredKey: preferredKey) : auto
        let unknownPref = preferredKey != nil && !cams.contains { $0.key == preferredKey }
        let list: [[String: Any]] = cams.map { (c: PpgCam) -> [String: Any] in
            let readable = c.device.formats.filter { isReadableFormat($0) }
            let sizes: [[String: Any]] = readable
                .sorted { a, b in let (aw, ah) = dims(a); let (bw, bh) = dims(b); return aw * ah < bw * bh }
                .prefix(6).map { (f: AVCaptureDevice.Format) -> [String: Any] in
                    let (w, h) = dims(f)
                    return ["w": w, "h": h, "maxFps": maxRate(f)]
                }
            return [
                "key": c.key, "id": c.key, "logicalId": c.key, "physicalId": NSNull(), "kind": "single",
                "label": c.label, "hasFlash": c.hasFlash, "manualSensor": c.manual,
                "maxYuvFps": c.maxFps, "surfaceMaxFps": c.maxFps,
                "highSpeedFpsRanges": [Any](), "aeFpsRanges": [Any](), "physicalIds": [Any](),
                "smallYuvSizes": sizes,
                "meetsTarget": c.hasFlash && c.maxFps >= Double(targetFps) - 0.5,
                "meetsMinimum": pickFor(c, minFps: minFps) != nil,
                "reason": reason(c, minFps: minFps),
            ]
        }
        var out: [String: Any] = [
            "platform": "ios", "targetFps": targetFps, "minFps": minFps,
            "cameras": list, "hiddenPhysicalIds": [Any](),
            "requestedKeyUnknown": unknownPref,
            "anyMeetsMinimum": auto != nil,
            "meetsMinimum": chosen != nil,
            "meetsTarget": chosen != nil && chosen!.maxFps >= Double(targetFps) - 0.5,
            "supports60": cams.contains { pickFor($0, minFps: 60) != nil },
        ]
        out["autoKey"] = auto?.cam.key ?? NSNull()
        out["requestedKey"] = preferredKey ?? NSNull()
        if let c = chosen {
            out["chosen"] = ["key": c.cam.key, "id": c.cam.key, "label": c.cam.label, "w": c.width,
                             "h": c.height, "maxFps": c.maxFps, "manual": c.cam.manual] as [String: Any]
        } else {
            out["chosen"] = NSNull()
        }
        return out
    }
}
