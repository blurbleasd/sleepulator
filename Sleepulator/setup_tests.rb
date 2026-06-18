require 'xcodeproj'
require 'fileutils'

project_path = 'Sleepulator.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'Sleepulator' }

# Find and remove AudioMathTests.swift from main target
test_file_ref = main_target.source_build_phase.files_references.find { |f| f.real_path.to_s.end_with?('AudioMathTests.swift') }
if test_file_ref
  main_target.source_build_phase.remove_file_reference(test_file_ref)
  test_file_ref.remove_from_project
end

# Check if SleepulatorTests already exists
test_target = project.targets.find { |t| t.name == 'SleepulatorTests' }

if test_target.nil?
  # Create a new unit test target
  test_target = project.new_target(:unit_test_bundle, 'SleepulatorTests', :ios)
  
  test_target.build_configurations.each do |config|
    config.build_settings['TEST_HOST'] = "$(BUILT_PRODUCTS_DIR)/Sleepulator.app/Sleepulator"
    config.build_settings['BUNDLE_LOADER'] = "$(TEST_HOST)"
    config.build_settings['INFOPLIST_FILE'] = "SleepulatorTests/Info.plist"
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "app.sleepulator.SleepulatorTests"
    config.build_settings['SWIFT_VERSION'] = "5.0"
    config.build_settings['TARGETED_DEVICE_FAMILY'] = "1,2"
  end
  
  project.root_object.attributes['TargetAttributes'] ||= {}
  project.root_object.attributes['TargetAttributes'][test_target.uuid] = {
    'TestTargetID' => main_target.uuid
  }
  
  test_target.add_dependency(main_target)
end

FileUtils.mkdir_p('SleepulatorTests')
if File.exist?('Sleepulator/Services/AudioMathTests.swift')
  FileUtils.mv('Sleepulator/Services/AudioMathTests.swift', 'SleepulatorTests/AudioMathTests.swift')
end

test_group = project.main_group.find_subpath('SleepulatorTests', true)

unless File.exist?('SleepulatorTests/Info.plist')
  File.write('SleepulatorTests/Info.plist', <<~PLIST)
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST
end

# Add Info.plist to project if missing
info_ref = test_group.files.find { |f| f.path == 'Info.plist' } || test_group.new_file('Info.plist')

# Add swift file
new_test_ref = test_group.files.find { |f| f.path == 'AudioMathTests.swift' } || test_group.new_file('AudioMathTests.swift')
unless test_target.source_build_phase.files_references.include?(new_test_ref)
  test_target.source_build_phase.add_file_reference(new_test_ref)
end

project.save
puts "Successfully setup SleepulatorTests target and moved AudioMathTests.swift."
