# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_llvm"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvLlvmTest < Minitest::Test
  # --- provisioned? ---

  test "provisioned? returns true when lisp file matches prefix" do
    Given "a project root with matching 520_llvm.lisp"
    llvm_prefix = "/opt/homebrew/opt/llvm"
    tmpdir = Dir.mktmpdir("shadowenv-llvm-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "520_llvm.lisp"),
      ShadowenvLlvm.generate_llvm_lisp(llvm_prefix)
    )

    Expect ".provisioned? returns true"
    ShadowenvLlvm.provisioned?(llvm_prefix, project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when lisp file has different prefix" do
    Given "a project root with 520_llvm.lisp for a different prefix"
    tmpdir = Dir.mktmpdir("shadowenv-llvm-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "520_llvm.lisp"),
      ShadowenvLlvm.generate_llvm_lisp("/usr/local/opt/llvm")
    )

    Expect ".provisioned? returns false for different prefix"
    ShadowenvLlvm.provisioned?("/opt/homebrew/opt/llvm", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when .shadowenv.d does not exist" do
    Given "a project root without .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-llvm-test-")

    Expect ".provisioned? returns false"
    ShadowenvLlvm.provisioned?("/opt/homebrew/opt/llvm", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- generate_llvm_lisp ---

  test "generate_llvm_lisp contains provide directive with prefix" do
    When "we generate lisp"
    result = ShadowenvLlvm.generate_llvm_lisp("/opt/homebrew/opt/llvm")

    Then "the provide directive includes the prefix"
    assert_includes result, '(provide "llvm" "/opt/homebrew/opt/llvm")'
  end

  test "generate_llvm_lisp prepends llvm bin to PATH" do
    When "we generate lisp"
    result = ShadowenvLlvm.generate_llvm_lisp("/opt/homebrew/opt/llvm")

    Then "PATH includes llvm bin"
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/opt/homebrew/opt/llvm/bin")'
  end

  test "generate_llvm_lisp sets CC" do
    When "we generate lisp"
    result = ShadowenvLlvm.generate_llvm_lisp("/opt/homebrew/opt/llvm")

    Then "CC is set to clang"
    assert_includes result, '(env/set "CC" "/opt/homebrew/opt/llvm/bin/clang")'
  end

  test "generate_llvm_lisp sets CXX" do
    When "we generate lisp"
    result = ShadowenvLlvm.generate_llvm_lisp("/opt/homebrew/opt/llvm")

    Then "CXX is set to clang++"
    assert_includes result, '(env/set "CXX" "/opt/homebrew/opt/llvm/bin/clang++")'
  end

  test "generate_llvm_lisp sets LDFLAGS with rpath" do
    When "we generate lisp"
    result = ShadowenvLlvm.generate_llvm_lisp("/opt/homebrew/opt/llvm")

    Then "LDFLAGS includes the c++ lib path"
    assert_includes result, '(env/set "LDFLAGS" "-L/opt/homebrew/opt/llvm/lib/c++ -Wl,-rpath,/opt/homebrew/opt/llvm/lib/c++")'
  end

  # --- setup! ---

  test "setup! writes lisp file and returns true" do
    Given "a project root and a valid LLVM prefix"
    tmpdir = Dir.mktmpdir("shadowenv-llvm-setup-")
    llvm_prefix = "/opt/homebrew/opt/llvm"

    When "we call setup!"
    result = ShadowenvLlvm.setup!(project_root: tmpdir, llvm_prefix: llvm_prefix)

    Then "it returns true and writes the lisp file"
    _ * ShadowenvLlvm.method(:system) >> true
    result == true
    lisp_path = File.join(tmpdir, ".shadowenv.d", "520_llvm.lisp")
    assert File.exist?(lisp_path), "Expected lisp file at #{lisp_path}"
    content = File.read(lisp_path)
    assert_includes content, '(provide "llvm"'

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! returns false when no prefix is available" do
    Given "no LLVM prefix"

    When "we call setup! without a prefix"
    result = ShadowenvLlvm.setup!(project_root: Dir.mktmpdir("shadowenv-llvm-none-"), llvm_prefix: nil)

    Then "it returns false"
    _ * ShadowenvLlvm.detect_llvm_prefix >> nil
    result == false
  end

  # --- ci_or_linux? ---

  test "ci_or_linux? returns true when CI env is set" do
    Given "CI=true"
    original = ENV["CI"]
    ENV["CI"] = "true"

    Expect "ci_or_linux? returns true"
    ShadowenvLlvm.ci_or_linux? == true

    Cleanup
    ENV["CI"] = original
  end

  test "ci_or_linux? returns false on macOS without CI" do
    Given "no CI env and macOS platform"
    original = ENV["CI"]
    ENV.delete("CI")

    When "we check ci_or_linux? on a non-linux platform"
    result = ShadowenvLlvm.ci_or_linux?

    Then "it returns false (assuming test runs on macOS)"
    result == false unless RUBY_PLATFORM.include?("linux")

    Cleanup
    ENV["CI"] = original if original
  end
end
