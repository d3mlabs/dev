# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_xcode"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvXcodeTest < Minitest::Test
  DEVELOPER_DIR = "/Applications/Xcode-26.1.1.app/Contents/Developer"

  test "generate_xcode_lisp provides xcode and sets DEVELOPER_DIR" do
    When "generating lisp for the pin"
    result = ShadowenvXcode.generate_xcode_lisp("26.1.1", DEVELOPER_DIR)

    Then "it provides the pinned version and points DEVELOPER_DIR at it"
    assert_includes result, '(provide "xcode" "26.1.1")'
    assert_includes result, %((env/set "DEVELOPER_DIR" "#{DEVELOPER_DIR}"))
  end

  test "provisioned? returns true when the lisp pins the same developer dir" do
    Given "a 520_xcode.lisp provisioned for the pin"
    tmpdir = Dir.mktmpdir("shadowenv-xcode-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "520_xcode.lisp"),
      ShadowenvXcode.generate_xcode_lisp("26.1.1", DEVELOPER_DIR),
    )

    Expect
    ShadowenvXcode.provisioned?(DEVELOPER_DIR, project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when no lisp file exists" do
    Given "an empty project root"
    tmpdir = Dir.mktmpdir("shadowenv-xcode-test-")

    Expect
    ShadowenvXcode.provisioned?(DEVELOPER_DIR, project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false for a different developer dir" do
    Given "a lisp provisioned for another Xcode version"
    tmpdir = Dir.mktmpdir("shadowenv-xcode-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "520_xcode.lisp"),
      ShadowenvXcode.generate_xcode_lisp("16.4", "/Applications/Xcode-16.4.app/Contents/Developer"),
    )

    Expect
    ShadowenvXcode.provisioned?(DEVELOPER_DIR, project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! writes the lisp file and returns true" do
    Given "a temporary project directory"
    tmpdir = Dir.mktmpdir("shadowenv-xcode-setup-")

    When "running setup! with the shadowenv trust call stubbed"
    result = ShadowenvXcode.setup!(project_root: tmpdir, version: "26.1.1", developer_dir: DEVELOPER_DIR)

    Then "the lisp file exists with the pin"
    _ * Kernel.system >> true
    result == true
    content = File.read(File.join(tmpdir, ".shadowenv.d", "520_xcode.lisp"))
    assert_includes content, '(provide "xcode" "26.1.1")'
    assert_includes content, DEVELOPER_DIR

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
