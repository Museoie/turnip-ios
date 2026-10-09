platform :ios, '16.0'
use_frameworks!

target 'Turnip' do
  pod 'TensorFlowLiteSwift', '~> 2.17.0'

  target 'TurnipTests' do
    inherit! :search_paths
  end
end

# Xcode 26+ errors on any target whose IPHONEOS_DEPLOYMENT_TARGET is below
# 15.0. TensorFlowLiteSwift 2.17.0's podspec still declares 12.0, and `pod
# install` (run by ci_scripts/ci_post_clone.sh on Xcode Cloud) copies the
# podspec's value onto the generated Pods targets — the Podfile's
# `platform :ios, '16.0'` only gates dependency resolution, it doesn't
# rewrite the generated targets. So Xcode Cloud's archive dies with:
#   "The iOS deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 12.0,
#    but the range of supported deployment target versions is 15.0 to 27.0.x."
# Raise every pod target sitting below the app's minimum deployment target so
# the generated Pods.xcodeproj archives on current Xcode.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
      if current.nil? || Gem::Version.new(current) < Gem::Version.new('16.0')
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      end

      # TensorFlowLiteSwift 2.17.0's Model.swift calls the deprecated
      # Data.withUnsafeBytes(_:) overload (the one taking a typed pointer);
      # there's no newer pod release with a fix. It's vendored code we don't
      # own, so silence just this one deprecation warning for this target
      # rather than editing the checked-out pod source (pod install/update
      # would overwrite it anyway).
      if target.name == 'TensorFlowLiteSwift'
        config.build_settings['OTHER_SWIFT_FLAGS'] = ['$(inherited)', '-suppress-warnings']
      end
    end
  end
end
