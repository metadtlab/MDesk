#!/usr/bin/env ruby
# Verify the packaged app, not just the source manifests, before App Store upload.
# Usage: ruby ios/verify_privacy.rb /path/to/Runner.app [expected-build-number]
require 'json'
require 'open3'

app = ARGV.fetch(0) { abort 'Usage: verify_privacy.rb Runner.app [build-number]' }
abort "App bundle not found: #{app}" unless File.directory?(app)

def read_plist(path)
  output, error, status = Open3.capture3('plutil', '-convert', 'json', '-o', '-', path)
  abort "Invalid plist #{path}: #{error}" unless status.success?
  JSON.parse(output)
end

info = read_plist(File.join(app, 'Info.plist'))
if ARGV[1] && info['CFBundleVersion'] != ARGV[1]
  abort "Unexpected build number: #{info['CFBundleVersion']} (expected #{ARGV[1]})"
end

# Xcode 27 / iOS 27 requires the scene lifecycle before UIKit can launch the app.
# Check the packaged manifest so a source-only migration cannot silently regress.
scene_manifest = info['UIApplicationSceneManifest']
abort 'Missing UIApplicationSceneManifest (iOS 27 launch requirement)' unless scene_manifest.is_a?(Hash)
abort 'MDesk supports a single Flutter scene only' unless scene_manifest['UIApplicationSupportsMultipleScenes'] == false
app_scenes = scene_manifest.fetch('UISceneConfigurations', {})['UIWindowSceneSessionRoleApplication']
unless app_scenes.is_a?(Array) && app_scenes.any? { |scene|
  scene['UISceneClassName'] == 'UIWindowScene' &&
    scene['UISceneDelegateClassName'] == 'FlutterSceneDelegate' &&
    scene['UISceneStoryboardFile'] == 'Main'
}
  abort 'Missing FlutterSceneDelegate/Main scene configuration'
end
puts 'Flutter scene lifecycle packaging verified'

# SDKs present in MDesk and covered by Apple's third-party SDK requirements.
# Flutter plugins can package their manifest inside a resource bundle.
required_frameworks = %w[
  Flutter device_info_plus package_info_plus DKImagePickerController DKPhotoGallery
  SwiftyGif SDWebImage file_picker image_picker_ios path_provider_foundation
  sqflite_darwin url_launcher_ios video_player_avfoundation
]
required_frameworks.each do |name|
  framework = File.join(app, 'Frameworks', "#{name}.framework")
  abort "Missing expected framework: #{name}" unless File.directory?(framework)
  manifests = Dir.glob(File.join(framework, '**', 'PrivacyInfo.xcprivacy'))
  abort "Missing privacy manifest in #{name}.framework" if manifests.empty?
  puts "#{name}: #{manifests.length} manifest(s)"
end

app_manifest_path = File.join(app, 'PrivacyInfo.xcprivacy')
abort 'Missing app-level PrivacyInfo.xcprivacy' unless File.file?(app_manifest_path)
app_manifest = read_plist(app_manifest_path)
apis = app_manifest.fetch('NSPrivacyAccessedAPITypes')
unless apis.any? { |entry|
  entry['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryFileTimestamp' &&
    entry.fetch('NSPrivacyAccessedAPITypeReasons').include?('C617.1')
}
  abort 'Missing app-container file timestamp reason C617.1'
end

expected_data_types = %w[
  NSPrivacyCollectedDataTypeUserID NSPrivacyCollectedDataTypeDeviceID
  NSPrivacyCollectedDataTypeProductInteraction NSPrivacyCollectedDataTypeOtherUserContent
  NSPrivacyCollectedDataTypeOtherDiagnosticData NSPrivacyCollectedDataTypePurchaseHistory
  NSPrivacyCollectedDataTypeEmailAddress NSPrivacyCollectedDataTypePhoneNumber
  NSPrivacyCollectedDataTypeOtherDataTypes
]
collected = app_manifest.fetch('NSPrivacyCollectedDataTypes')
unless collected.map { |entry| entry.fetch('NSPrivacyCollectedDataType') }.sort == expected_data_types.sort
  abort 'App manifest does not match the App Store privacy data types'
end
unless collected.all? { |entry|
  entry['NSPrivacyCollectedDataTypeLinked'] == true &&
    entry['NSPrivacyCollectedDataTypeTracking'] == false &&
    entry['NSPrivacyCollectedDataTypePurposes'] == ['NSPrivacyCollectedDataTypePurposeAppFunctionality']
}
  abort 'App manifest does not match the App Store privacy purposes/linkage'
end
abort 'Unexpected app tracking declaration' unless app_manifest['NSPrivacyTracking'] == false

allowed_keys = %w[NSPrivacyTracking NSPrivacyTrackingDomains NSPrivacyCollectedDataTypes NSPrivacyAccessedAPITypes]
Dir.glob(File.join(app, '**', 'PrivacyInfo.xcprivacy')).each do |path|
  manifest = read_plist(path)
  unknown = manifest.keys - allowed_keys
  abort "Unknown privacy manifest keys in #{path}: #{unknown.join(', ')}" unless unknown.empty?
  %w[NSPrivacyTrackingDomains NSPrivacyCollectedDataTypes NSPrivacyAccessedAPITypes].each do |key|
    abort "Invalid #{key} in #{path}" if manifest.key?(key) && !manifest[key].is_a?(Array)
  end
  if manifest.key?('NSPrivacyTracking') && ![true, false].include?(manifest['NSPrivacyTracking'])
    abort "Invalid NSPrivacyTracking in #{path}"
  end
end
puts "Privacy packaging verified: #{info['CFBundleShortVersionString']} (#{info['CFBundleVersion']})"
