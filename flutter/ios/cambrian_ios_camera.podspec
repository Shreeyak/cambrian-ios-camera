Pod::Spec.new do |s|
  s.name             = 'cambrian_ios_camera'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin wrapping CameraKit for iOS-only camera access.'
  s.description      = s.summary
  s.homepage         = 'https://github.com/Shreeyak/cambrian-ios-camera'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Cambrian' => 'noreply@cambrian.dev' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '26.0'
  # SPM is the supported iOS integration (see Package.swift: Swift 5 language
  # mode + .Cxx interop). This podspec is a Flutter plugin-validation shim, not
  # the primary build path — keep swift_version aligned with Package.swift.
  s.swift_version    = '5.0'
  s.dependency 'Flutter'
  s.source_files     = 'cambrian_ios_camera/Sources/cambrian_ios_camera/**/*.swift'
  s.resource_bundles = { 'cambrian_ios_camera_privacy' => ['cambrian_ios_camera/Sources/cambrian_ios_camera/Resources/PrivacyInfo.xcprivacy'] }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
