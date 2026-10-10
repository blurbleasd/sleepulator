require 'xcodeproj'

# Adds the SleepulatorUITests target (XCUITest) and puts it in the shared Sleepulator scheme's
# test action, so `xcodebuild test -scheme Sleepulator` (and CI) runs it beside the unit tests.
# Idempotent: safe to run again. Run from this directory: `ruby setup_ui_tests.rb`.

project_path = 'Sleepulator.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'Sleepulator' }
ui_target = project.targets.find { |t| t.name == 'SleepulatorUITests' }

if ui_target.nil?
  ui_target = project.new_target(:ui_test_bundle, 'SleepulatorUITests', :ios, '17.0')

  ui_target.build_configurations.each do |config|
    config.build_settings['TEST_TARGET_NAME'] = 'Sleepulator'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.sleepulator.SleepulatorUITests'
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['DEVELOPMENT_TEAM'] = 'C84UD6LFJQ'
  end

  project.root_object.attributes['TargetAttributes'] ||= {}
  project.root_object.attributes['TargetAttributes'][ui_target.uuid] = {
    'TestTargetID' => main_target.uuid
  }

  ui_target.add_dependency(main_target)
end

group = project.main_group.find_subpath('SleepulatorUITests', true)
group.set_source_tree('<group>')
group.set_path('SleepulatorUITests')

Dir.glob('SleepulatorUITests/*.swift').sort.each do |path|
  name = File.basename(path)
  ref = group.files.find { |f| f.path == name } || group.new_file(name)
  unless ui_target.source_build_phase.files_references.include?(ref)
    ui_target.source_build_phase.add_file_reference(ref)
  end
end

project.save

scheme_path = Xcodeproj::XCScheme.shared_data_dir(project_path) + 'Sleepulator.xcscheme'
scheme = Xcodeproj::XCScheme.new(scheme_path)
already = scheme.test_action.testables.any? do |t|
  t.buildable_references.any? { |r| r.target_name == 'SleepulatorUITests' }
end
unless already
  scheme.test_action.add_testable(Xcodeproj::XCScheme::TestAction::TestableReference.new(ui_target))
  scheme.save_as(project_path, 'Sleepulator', true)
end

puts 'SleepulatorUITests target ready and in the Sleepulator scheme.'
