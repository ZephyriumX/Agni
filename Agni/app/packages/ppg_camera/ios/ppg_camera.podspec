#
# CocoaPods spec for the Agni-Pulse ppg_camera plugin (iOS, AVFoundation).
# Deployment target 13.0: the code uses AVCaptureDevice.DiscoverySession (iOS 10) and
# .builtInUltraWideCamera (iOS 13). Only system frameworks are linked; no third-party pods.
#
Pod::Spec.new do |s|
  s.name             = 'ppg_camera'
  s.version          = '0.2.0'
  s.summary          = 'Raw-frame PPG capture (AVFoundation): torch, custom exposure, sensor timestamps.'
  s.description      = 'Local plugin of the Agni-Pulse app. Streams per-frame RGB ROI means with presentation timestamps.'
  s.homepage         = 'https://github.com/agni-pulse/agni-pulse'
  s.license          = { :type => 'Proprietary', :text => 'Private project. Not for redistribution.' }
  s.author           = { 'Agni-Pulse' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'AVFoundation', 'CoreMedia', 'CoreVideo'
  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
