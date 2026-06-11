# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_unreal"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvUnrealTest < Minitest::Test
  def create_fake_ue_root(dir)
    version_dir = File.join(dir, "Engine", "Build")
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, "Build.version"), '{"MajorVersion":5}')
    FileUtils.mkdir_p(File.join(dir, "Engine", "Binaries", "Mac"))
    dir
  end

  # --- provisioned? ---

  test "provisioned? returns true when lisp file matches UE root" do
    Given "a project root with matching 530_unreal.lisp"
    ue_root = "/opt/UnrealEngine"
    tmpdir = Dir.mktmpdir("shadowenv-unreal-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "530_unreal.lisp"),
      ShadowenvUnreal.generate_unreal_lisp(ue_root),
    )

    Expect
    ShadowenvUnreal.provisioned?(ue_root, project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when lisp file has different root" do
    Given "a project root with 530_unreal.lisp for a different UE root"
    tmpdir = Dir.mktmpdir("shadowenv-unreal-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "530_unreal.lisp"),
      ShadowenvUnreal.generate_unreal_lisp("/old/engine"),
    )

    Expect
    ShadowenvUnreal.provisioned?("/new/engine", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when .shadowenv.d does not exist" do
    Given "a project root without .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-unreal-test-")

    Expect
    ShadowenvUnreal.provisioned?("/opt/UnrealEngine", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- generate_unreal_lisp ---

  test "generate_unreal_lisp contains provide directive with UE root" do
    When "generating lisp"
    result = ShadowenvUnreal.generate_unreal_lisp("/opt/UnrealEngine")

    Then
    assert_includes result, '(provide "unreal" "/opt/UnrealEngine")'
  end

  test "generate_unreal_lisp sets UE_ROOT" do
    When "generating lisp"
    result = ShadowenvUnreal.generate_unreal_lisp("/opt/UnrealEngine")

    Then
    assert_includes result, '(env/set "UE_ROOT" "/opt/UnrealEngine")'
  end

  test "generate_unreal_lisp prepends engine binaries to PATH" do
    When "generating lisp"
    result = ShadowenvUnreal.generate_unreal_lisp("/opt/UnrealEngine")

    Then
    assert_includes result, '(env/prepend-to-pathlist "PATH"'
    assert_includes result, "/opt/UnrealEngine/Engine/Binaries/"
  end

  test "generate_unreal_lisp includes UE_PROJECT when specified" do
    When "generating lisp with a project path"
    result = ShadowenvUnreal.generate_unreal_lisp(
      "/opt/UnrealEngine",
      ue_project: "/project/FactoryGame.uproject",
    )

    Then
    assert_includes result, '(env/set "UE_PROJECT" "/project/FactoryGame.uproject")'
  end

  test "generate_unreal_lisp omits UE_PROJECT when nil" do
    When "generating lisp without a project path"
    result = ShadowenvUnreal.generate_unreal_lisp("/opt/UnrealEngine")

    Then
    refute_includes result, "UE_PROJECT"
  end

  # --- setup! ---

  test "setup! writes lisp file and returns true" do
    Given "a project root and a valid UE root"
    tmpdir = Dir.mktmpdir("shadowenv-unreal-setup-")
    ue_root = create_fake_ue_root(Dir.mktmpdir("fake-ue-"))

    When "calling setup!"
    result = ShadowenvUnreal.setup!(project_root: tmpdir, ue_root: ue_root)

    Then
    _ * ShadowenvUnreal.method(:system) >> true
    result == true
    lisp_path = File.join(tmpdir, ".shadowenv.d", "530_unreal.lisp")
    assert File.exist?(lisp_path), "Expected lisp file at #{lisp_path}"
    content = File.read(lisp_path)
    assert_includes content, '(provide "unreal"'

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! returns false when no UE root is available" do
    When "calling setup! without a root"
    result = ShadowenvUnreal.setup!(
      project_root: Dir.mktmpdir("shadowenv-unreal-none-"),
      ue_root: nil,
    )

    Then
    _ * ShadowenvUnreal.method(:detect_ue_root) >> nil
    result == false
  end

  test "setup! includes UE_PROJECT in lisp when specified" do
    Given "a project root and both UE root and project"
    tmpdir = Dir.mktmpdir("shadowenv-unreal-setup-")
    ue_root = create_fake_ue_root(Dir.mktmpdir("fake-ue-"))

    When "calling setup! with ue_project"
    ShadowenvUnreal.setup!(
      project_root: tmpdir,
      ue_root: ue_root,
      ue_project: "/project/FactoryGame.uproject",
    )
    content = File.read(File.join(tmpdir, ".shadowenv.d", "530_unreal.lisp"))

    Then
    _ * ShadowenvUnreal.method(:system) >> true
    assert_includes content, "FactoryGame.uproject"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- valid_ue_root? ---

  test "valid_ue_root? returns true for directory with Build.version" do
    Given "a fake UE root"
    ue_root = create_fake_ue_root(Dir.mktmpdir("fake-ue-"))

    Expect
    ShadowenvUnreal.send(:valid_ue_root?, ue_root) == true

    Cleanup
    FileUtils.rm_rf(ue_root)
  end

  test "valid_ue_root? returns false for empty directory" do
    Given "an empty directory"
    tmpdir = Dir.mktmpdir("not-ue-")

    Expect
    ShadowenvUnreal.send(:valid_ue_root?, tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- ci_or_linux? ---

  test "ci_or_linux? returns true when CI env is set" do
    Given "CI=true"
    original = ENV["CI"]
    ENV["CI"] = "true"

    Expect
    ShadowenvUnreal.ci_or_linux? == true

    Cleanup
    ENV["CI"] = original
  end

  test "ci_or_linux? without CI env reflects platform" do
    Given "no CI env"
    original = ENV["CI"]
    ENV.delete("CI")

    When "checking ci_or_linux?"
    result = ShadowenvUnreal.ci_or_linux?

    Then
    result == RUBY_PLATFORM.include?("linux")

    Cleanup
    ENV["CI"] = original if original
  end
end
