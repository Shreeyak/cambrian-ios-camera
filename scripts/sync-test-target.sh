#!/usr/bin/env bash
# sync-test-target.sh — dual-membership wiring for CameraKitTests.
#
# Re-runs the xcodeproj-side wiring that compiles every .swift file in
# CameraKit/Tests/CameraKitTests/ inside the ios_example_appTests Xcode
# target (host-app-hosted, runnable on physical iPad). The SwiftPM
# testTarget in CameraKit/Package.swift is left untouched — that's the
# package's portability contract when CameraKit is extracted to its own
# repo (tests use a host app, not tool-hosted, on device destinations).
#
# Idempotent. Run after adding a new test file in a future stage:
#   touch CameraKit/Tests/CameraKitTests/Stage12FooTests.swift
#   scripts/sync-test-target.sh
#
# Never hand-edit project.pbxproj — drive it through
# the xcodeproj gem.

set -euo pipefail

cd "$(dirname "$0")/.."

ruby <<'RUBY'
require 'set'
require 'xcodeproj'

PROJECT          = 'ios_example_app/ios_example_app.xcodeproj'
TEST_TARGET_NAME = 'ios_example_appTests'
APP_TARGET_NAME  = 'ios_example_app'
SOURCE_DIR       = 'CameraKit/Tests/CameraKitTests'
GROUP_NAME       = 'CameraKitTests'

project     = Xcodeproj::Project.open(PROJECT)
test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }
app_target  = project.targets.find { |t| t.name == APP_TARGET_NAME }
abort "test target #{TEST_TARGET_NAME} not found" unless test_target
abort "app target #{APP_TARGET_NAME} not found"   unless app_target

group = project.main_group.children.find { |c| c.display_name == GROUP_NAME }
unless group
  group = project.main_group.new_group(GROUP_NAME, SOURCE_DIR)
end

existing_real_paths = test_target.source_build_phase.files
                                 .map { |f| f.file_ref&.real_path&.to_s }
                                 .compact
                                 .map { |s| File.expand_path(s) }
                                 .to_set

added = []
Dir.glob("#{SOURCE_DIR}/*.swift").sort.each do |path|
  abs = File.expand_path(path)
  next if existing_real_paths.include?(abs)
  filename = File.basename(path)
  ref = group.files.find { |f| f.path == filename } ||
        group.new_reference(filename)
  test_target.source_build_phase.add_file_reference(ref)
  added << filename
end

# CameraKit package product: dual-presence — both as a
# package_product_dependency and as a PBXBuildFile with product_ref in
# the frameworks build phase — SPM package
# products use product_ref, NOT file_ref.
unless test_target.package_product_dependencies.any? { |d| d.product_name == 'CameraKit' }
  camerakit_dep = app_target.package_product_dependencies
                            .find { |d| d.product_name == 'CameraKit' }
  abort "CameraKit package product not found on app target" unless camerakit_dep
  test_target.package_product_dependencies << camerakit_dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = camerakit_dep
  test_target.frameworks_build_phase.files << bf
end

test_target.build_configurations.each do |cfg|
  cfg.build_settings['ENABLE_TESTABILITY'] = 'YES'
end

project.save
puts "Added: #{added.empty? ? '(nothing — already in sync)' : added.join(', ')}"
RUBY
