# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_path"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvPathTest < Minitest::Test
  FILENAME = "515_brew.lisp"

  test "generate_path_lisp provides the record and prepends every path in order" do
    When "generating lisp for two bins"
    result = Dev::ShadowenvPath.generate_path_lisp(
      provide: ["brew", "cmake@4.4.3 llvm@18@18.1.8"],
      paths: ["/opt/homebrew/Cellar/cmake/4.4.3/bin", "/opt/homebrew/Cellar/llvm@18/18.1.8_1/bin"],
    )

    Then "the provide line comes first and each path is a PATH prepend, in the given order"
    lines = result.lines.map(&:strip).reject(&:empty?)
    lines == [
      '(provide "brew" "cmake@4.4.3 llvm@18@18.1.8")',
      '(env/prepend-to-pathlist "PATH" "/opt/homebrew/Cellar/cmake/4.4.3/bin")',
      '(env/prepend-to-pathlist "PATH" "/opt/homebrew/Cellar/llvm@18/18.1.8_1/bin")',
    ]
  end

  test "setup! writes the lisp, trusts the project and reports a change" do
    Given "a project root with no shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-path-test-")

    When "activating one path"
    changed = Dev::ShadowenvPath.setup!(
      project_root: tmpdir, filename: FILENAME, provide: ["brew", "cmake@4.4.3"], paths: ["/x/bin"],
    )

    Then "the file holds the generated lisp, shadowenv was trusted, and the call reports the write"
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    changed == true
    File.read(File.join(tmpdir, ".shadowenv.d", FILENAME)) ==
      Dev::ShadowenvPath.generate_path_lisp(provide: ["brew", "cmake@4.4.3"], paths: ["/x/bin"])

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! is a no-op when the file already holds the same activation" do
    Given "a project already activated for this exact set"
    tmpdir = Dir.mktmpdir("shadowenv-path-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, FILENAME),
      Dev::ShadowenvPath.generate_path_lisp(provide: ["brew", "cmake@4.4.3"], paths: ["/x/bin"]),
    )

    When "activating the same set again"
    changed = Dev::ShadowenvPath.setup!(
      project_root: tmpdir, filename: FILENAME, provide: ["brew", "cmake@4.4.3"], paths: ["/x/bin"],
    )

    Then "nothing is written or trusted, and the call reports no change"
    0 * Kernel.system
    changed == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! rewrites when the activated set moved" do
    Given "a project activated for an older version"
    tmpdir = Dir.mktmpdir("shadowenv-path-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, FILENAME),
      Dev::ShadowenvPath.generate_path_lisp(provide: ["brew", "cmake@4.4.3"], paths: ["/old/bin"]),
    )

    When "activating the new version"
    changed = Dev::ShadowenvPath.setup!(
      project_root: tmpdir, filename: FILENAME, provide: ["brew", "cmake@4.5.0"], paths: ["/new/bin"],
    )

    Then "the file now names only the new path"
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    changed == true
    content = File.read(File.join(shadowenv_d, FILENAME))
    content.include?("/new/bin")
    !content.include?("/old/bin")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! with no paths still writes the provide so a stale activation is cleared" do
    Given "a project activated for a path that no longer applies"
    tmpdir = Dir.mktmpdir("shadowenv-path-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, FILENAME),
      Dev::ShadowenvPath.generate_path_lisp(provide: ["brew", "cmake@4.4.3"], paths: ["/old/bin"]),
    )

    When "activating an empty set"
    Dev::ShadowenvPath.setup!(project_root: tmpdir, filename: FILENAME, provide: ["brew", ""], paths: [])

    Then "the file carries the provide and no prepend"
    1 * Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL) >> true
    content = File.read(File.join(shadowenv_d, FILENAME))
    content.include?('(provide "brew" "")')
    !content.include?("prepend-to-pathlist")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
