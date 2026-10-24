# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_python"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvPythonTest < Minitest::Test
  test "generate_python_lisp contains the provide directive" do
    When "generating lisp for 3.12"
    result = Dev::ShadowenvPython.generate_python_lisp("3.12", "/tmp/proj/.venv")

    Then "the lisp declares the provided version"
    assert_includes result, '(provide "python" "3.12")'
  end

  test "generate_python_lisp activates the venv on PATH and VIRTUAL_ENV by absolute path" do
    When "generating lisp for 3.12"
    result = Dev::ShadowenvPython.generate_python_lisp("3.12", "/tmp/proj/.venv")

    Then "it sets VIRTUAL_ENV + PYTHONHOME and prepends the venv bin as a literal path"
    assert_includes result, '(env/set "VIRTUAL_ENV" "/tmp/proj/.venv")'
    assert_includes result, '(env/set "PYTHONHOME" ())'
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/tmp/proj/.venv/bin")'
  end


  test "activate! builds the project venv on the keg's pythonX.Y and writes the lisp" do
    Given "a project root and the locked Python's keg"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the venv was built by the keg's interpreter and the lisp activates it"
    File.read(log).lines.first.start_with?("-m venv #{File.join(tmpdir, ".venv")}")
    File.executable?(File.join(tmpdir, ".venv", "bin", "python")) == true
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "540_python.lisp"))
    lisp.include?('(provide "python" "3.12.8")')
    lisp.include?(%((env/set "VIRTUAL_ENV" "#{File.join(tmpdir, ".venv")}")))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! rebuilds a venv that was built on another interpreter, and keeps one built on the locked keg" do
    Given "a venv built on some other Python"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = /elsewhere/python@3.11/bin\nversion = 3.11.9\n")

    When "activating twice"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the first activation rebuilt the venv on the keg; the second left it alone"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1
    File.read(File.join(venv, "pyvenv.cfg")).include?("home = #{keg / "bin"}")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end


  test "activate! raises when the keg's pythonX.Y cannot build the venv" do
    Given "a keg whose interpreter fails -m venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    FileUtils.mkdir_p(keg / "bin")
    write_fake_executable((keg / "bin" / "python3.12").to_s, "#!/bin/sh\nexit 1\n")

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the error names the failed venv creation"
    error = raises Dev::ShadowenvPython::VenvError
    error.message.include?("-m venv")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_pip! bootstraps pip via ensurepip when it is missing" do
    Given "a venv python without pip whose ensurepip succeeds"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    log = File.join(tmpdir, "invocations.log")
    venv_python = write_fake_executable(File.join(tmpdir, "python"), <<~SCRIPT)
      #!/bin/sh
      echo "$@" >> "#{log}"
      case "$2" in
        pip) exit 1 ;;
      esac
      exit 0
    SCRIPT

    When "we ensure pip"
    Dev::ShadowenvPython.ensure_pip!(venv_python)

    Then "ensurepip ran"
    assert_includes File.read(log), "ensurepip --upgrade"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_pip! raises when pip cannot be bootstrapped" do
    Given "a venv python where both pip and ensurepip fail"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    venv_python = write_fake_executable(File.join(tmpdir, "python"), "#!/bin/sh\nexit 1\n")

    Expect "a VenvError about pip"
    error = assert_raises(Dev::ShadowenvPython::VenvError) do
      Dev::ShadowenvPython.ensure_pip!(venv_python)
    end
    assert_includes error.message, "pip"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  private

  # Writes an executable script and returns its path.
  def write_fake_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
    path
  end

  # A keg's bin/python3 stand-in: logs every invocation; `-m venv <dir>`
  # materializes a minimal venv whose pyvenv.cfg names this keg's bin as its
  # home, as a real venv's does. Returns the log path.
  def write_keg_python(keg)
    log = File.join(keg, "invocations.log")
    FileUtils.mkdir_p(File.join(keg, "bin"))
    script = [
      "#!/bin/sh",
      "echo \"$@\" >> \"#{log}\"",
      "if [ \"$1\" = \"-m\" ] && [ \"$2\" = \"venv\" ]; then",
      "  mkdir -p \"$3/bin\"",
      "  printf '#!/bin/sh\\nexit 0\\n' > \"$3/bin/python\"",
      "  chmod 755 \"$3/bin/python\"",
      "  printf 'home = %s\\nversion = 3.12.8\\n' \"#{File.join(keg, "bin")}\" > \"$3/pyvenv.cfg\"",
      "fi",
      "exit 0",
    ].join("\n")
    # brew\x27s python@X.Y keg ships bin/pythonX.Y only; the bare python3 lives
    # in libexec/bin and in the opt link, neither of which is the keg.
    write_fake_executable(File.join(keg, "bin", "python3.12"), script)
    log
  end
end
