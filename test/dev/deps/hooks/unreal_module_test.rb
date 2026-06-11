# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/hooks/unreal_module"
require "dev/deps/dependency"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::Hooks::UnrealModuleTest < Minitest::Test
  test "generates a .Build.cs wrapper in the dep's source directory" do
    Given "a fetched dependency with source"
    dir = Dir.mktmpdir("dev-unreal-module-test-")
    root = Pathname(dir)
    src_dir = root / "build" / "_deps" / "googletest-src"
    FileUtils.mkdir_p(src_dir)

    dep = Dev::Deps::Dependency.new(
      name: "googletest", integration: :cmake, group: :test,
      version: "sha1", hash: nil, metadata: {},
    )

    When "calling the hook"
    Dev::Deps::Hooks::UnrealModule.call(dep, root)

    Then
    build_cs = src_dir / "Googletest.Build.cs"
    build_cs.exist?
    content = File.read(build_cs)
    content.include?("public class Googletest : ModuleRules")
    content.include?("Type = ModuleType.External;")
    content.include?('"."')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "does not overwrite an existing .Build.cs" do
    Given "a dep source directory with an existing .Build.cs"
    dir = Dir.mktmpdir("dev-unreal-module-test-")
    root = Pathname(dir)
    src_dir = root / "build" / "_deps" / "mylib-src"
    FileUtils.mkdir_p(src_dir)
    build_cs = src_dir / "Mylib.Build.cs"
    File.write(build_cs, "existing content")

    dep = Dev::Deps::Dependency.new(
      name: "mylib", integration: :cmake, group: :app,
      version: "sha1", hash: nil, metadata: {},
    )

    When "calling the hook"
    Dev::Deps::Hooks::UnrealModule.call(dep, root)

    Then
    File.read(build_cs) == "existing content"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "skips when source directory does not exist" do
    Given "a project root with no fetched source"
    dir = Dir.mktmpdir("dev-unreal-module-test-")
    root = Pathname(dir)

    dep = Dev::Deps::Dependency.new(
      name: "missing", integration: :cmake, group: :test,
      version: "sha1", hash: nil, metadata: {},
    )

    When "calling the hook"
    Dev::Deps::Hooks::UnrealModule.call(dep, root)

    Then "no file created"
    !(root / "build" / "_deps" / "missing-src" / "Missing.Build.cs").exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "uses public_includes from metadata" do
    Given "a dep with custom public_includes"
    dir = Dir.mktmpdir("dev-unreal-module-test-")
    root = Pathname(dir)
    src_dir = root / "build" / "_deps" / "gtest-src"
    FileUtils.mkdir_p(src_dir)

    dep = Dev::Deps::Dependency.new(
      name: "gtest", integration: :cmake, group: :test,
      version: "sha1", hash: nil,
      metadata: { "public_includes" => ["googletest/include", "googlemock/include"] },
    )

    When "calling the hook"
    Dev::Deps::Hooks::UnrealModule.call(dep, root)

    Then
    content = File.read(src_dir / "Gtest.Build.cs")
    content.include?('"googletest/include"')
    content.include?('"googlemock/include"')

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "to_module_name converts hyphenated names to PascalCase" do
    Expect
    Dev::Deps::Hooks::UnrealModule.to_module_name("google-test") == "GoogleTest"
    Dev::Deps::Hooks::UnrealModule.to_module_name("googletest") == "Googletest"
    Dev::Deps::Hooks::UnrealModule.to_module_name("my_cool_lib") == "MyCoolLib"
  end
end
