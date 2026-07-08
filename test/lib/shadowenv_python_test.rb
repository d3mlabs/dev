# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_python"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvPythonTest < Minitest::Test
  test "generate_python_lisp contains the provide directive" do
    When "generating lisp for 3.12"
    result = ShadowenvPython.generate_python_lisp("3.12")

    Then "the lisp declares the provided version"
    assert_includes result, '(provide "python" "3.12")'
  end

  test "generate_python_lisp activates the project venv on PATH and VIRTUAL_ENV" do
    When "generating lisp for 3.12"
    result = ShadowenvPython.generate_python_lisp("3.12")

    Then "it sets VIRTUAL_ENV, clears PYTHONHOME, and prepends the venv bin"
    assert_includes result, "VIRTUAL_ENV"
    assert_includes result, ".venv"
    assert_includes result, "PYTHONHOME"
    assert_includes result, "prepend-to-pathlist"
  end

  test "provisioned? is true only when the lisp matches and the venv exists" do
    Given "a project with a matching lisp and a .venv directory"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    FileUtils.mkdir_p(File.join(tmpdir, ".venv"))
    File.write(File.join(shadowenv_d, "540_python.lisp"), ShadowenvPython.generate_python_lisp("3.12"))

    Expect "provisioned? returns true"
    ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? is false when the venv is missing even if the lisp exists" do
    Given "a matching lisp but no .venv directory"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(File.join(shadowenv_d, "540_python.lisp"), ShadowenvPython.generate_python_lisp("3.12"))

    Expect "provisioned? returns false"
    ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? is false for a different version" do
    Given "a lisp provisioned for 3.11 and a venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    FileUtils.mkdir_p(File.join(tmpdir, ".venv"))
    File.write(File.join(shadowenv_d, "540_python.lisp"), ShadowenvPython.generate_python_lisp("3.11"))

    Expect "provisioned? returns false for a mismatched version"
    ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
