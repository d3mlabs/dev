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

  test "provisioned? is true only when the lisp matches and the venv exists" do
    Given "a project with a matching lisp and a .venv directory"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    FileUtils.mkdir_p(File.join(tmpdir, ".venv"))
    File.write(File.join(shadowenv_d, "540_python.lisp"),
      Dev::ShadowenvPython.generate_python_lisp("3.12", File.join(tmpdir, ".venv")))

    Expect "provisioned? returns true"
    Dev::ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? is false when the venv is missing even if the lisp exists" do
    Given "a matching lisp but no .venv directory"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(File.join(shadowenv_d, "540_python.lisp"),
      Dev::ShadowenvPython.generate_python_lisp("3.12", File.join(tmpdir, ".venv")))

    Expect "provisioned? returns false"
    Dev::ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! writes the lisp and reports success" do
    Given "a project root and a provisionable venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    venv = File.join(tmpdir, ".venv")

    When "we run full provisioning"
    result = Dev::ShadowenvPython.setup!(python_version: "3.12", project_root: tmpdir)

    Then "the lisp is written and setup reports success"
    _ * Dev::ShadowenvPython.ensure_venv!(python_version: "3.12", project_root: tmpdir) >> venv
    result == true
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "540_python.lisp"))
    assert_includes lisp, '(provide "python" "3.12")'
    assert_includes lisp, %((env/set "VIRTUAL_ENV" "#{venv}"))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_venv! creates the venv with the resolved interpreter" do
    Given "a resolved interpreter that materializes a venv on demand"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    python_bin = write_venv_capable_python(tmpdir)

    When "we ensure the venv"
    result = Dev::ShadowenvPython.ensure_venv!(python_version: "3.12", project_root: tmpdir)

    Then "the venv exists at the project root with a working python"
    _ * Dev::ShadowenvPython.ensure_homebrew_python!("3.12") >> python_bin
    result == File.join(tmpdir, ".venv")
    File.executable?(File.join(tmpdir, ".venv", "bin", "python")) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_venv! reuses an existing venv without recreating it" do
    Given "a project with a venv already in place"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    venv_bin = File.join(tmpdir, ".venv", "bin")
    FileUtils.mkdir_p(venv_bin)
    write_fake_executable(File.join(venv_bin, "python"), "#!/bin/sh\nexit 0\n")
    failing_python = write_fake_executable(File.join(tmpdir, "python-never-called"), "#!/bin/sh\nexit 1\n")

    When "we ensure the venv"
    result = Dev::ShadowenvPython.ensure_venv!(python_version: "3.12", project_root: tmpdir)

    Then "the existing venv is returned and no interpreter call is needed"
    _ * Dev::ShadowenvPython.ensure_homebrew_python!("3.12") >> failing_python
    result == File.join(tmpdir, ".venv")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_venv! raises when venv creation fails" do
    Given "an installed formula whose interpreter cannot create a venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    write_fake_executable(File.join(prefix, "bin", "python3.12"), "#!/bin/sh\nexit 1\n")
    write_fake_brew(tmpdir, prefix: prefix)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    When "we ensure the venv"
    error = assert_raises(Dev::ShadowenvPython::BrewInstallError) do
      Dev::ShadowenvPython.ensure_venv!(python_version: "3.12", project_root: tmpdir)
    end

    Then "the error names the failed venv creation"
    assert_includes error.message, "-m venv"

    Cleanup
    ENV["PATH"] = original_path
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

    Expect "a BrewInstallError about pip"
    error = assert_raises(Dev::ShadowenvPython::BrewInstallError) do
      Dev::ShadowenvPython.ensure_pip!(venv_python)
    end
    assert_includes error.message, "pip"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? is false for a different version" do
    Given "a lisp provisioned for 3.11 and a venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    FileUtils.mkdir_p(File.join(tmpdir, ".venv"))
    File.write(File.join(shadowenv_d, "540_python.lisp"),
      Dev::ShadowenvPython.generate_python_lisp("3.11", File.join(tmpdir, ".venv")))

    Expect "provisioned? returns false for a mismatched version"
    Dev::ShadowenvPython.provisioned?("3.12", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- ensure_homebrew_python! ---

  test "ensure_homebrew_python! returns the versioned interpreter of an installed formula" do
    Given "an installed python@3.12 with a versioned interpreter"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    write_fake_executable(File.join(prefix, "bin", "python3.12"), "#!/bin/sh\nexit 0\n")
    write_fake_brew(tmpdir, prefix: prefix)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "the versioned interpreter path is returned"
    Dev::ShadowenvPython.ensure_homebrew_python!("3.12") == File.join(prefix, "bin", "python3.12")

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_python! installs the formula when it is missing" do
    Given "a brew without python@3.12 whose install succeeds"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    write_fake_executable(File.join(prefix, "bin", "python3.12"), "#!/bin/sh\nexit 0\n")
    log = write_fake_brew(tmpdir, prefix: prefix, list_exit: 1)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    When "we ensure the interpreter"
    result = Dev::ShadowenvPython.ensure_homebrew_python!("3.12")

    Then "brew install ran and the interpreter is returned"
    assert_includes File.read(log), "install python@3.12"
    result == File.join(prefix, "bin", "python3.12")

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_python! raises when brew install fails" do
    Given "a brew without python@3.12 whose install fails"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    write_fake_brew(tmpdir, prefix: tmpdir, list_exit: 1, install_exit: 1)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "a BrewInstallError naming the failed install"
    error = assert_raises(Dev::ShadowenvPython::BrewInstallError) do
      Dev::ShadowenvPython.ensure_homebrew_python!("3.12")
    end
    assert_includes error.message, "brew install python@3.12 failed"

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_python! raises when the formula prefix cannot be resolved" do
    Given "an installed formula whose prefix does not resolve"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    write_fake_brew(tmpdir, prefix: File.join(tmpdir, "no-such-prefix"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "a BrewInstallError about the prefix"
    error = assert_raises(Dev::ShadowenvPython::BrewInstallError) do
      Dev::ShadowenvPython.ensure_homebrew_python!("3.12")
    end
    assert_includes error.message, "could not resolve Homebrew prefix"

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_python! falls back to the formula's python3" do
    Given "an installed formula with only an unversioned python3"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    write_fake_executable(File.join(prefix, "bin", "python3"), "#!/bin/sh\nexit 0\n")
    write_fake_brew(tmpdir, prefix: prefix)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "the python3 fallback is returned"
    Dev::ShadowenvPython.ensure_homebrew_python!("3.12") == File.join(prefix, "bin", "python3")

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_python! raises when the formula ships no interpreter at all" do
    Given "an installed formula with an empty bin"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    write_fake_brew(tmpdir, prefix: prefix)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "a BrewInstallError about the missing interpreter"
    error = assert_raises(Dev::ShadowenvPython::BrewInstallError) do
      Dev::ShadowenvPython.ensure_homebrew_python!("3.12")
    end
    assert_includes error.message, "no python interpreter found"

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  # --- brew_prefix_for ---

  test "brew_prefix_for returns nil when brew is absent" do
    Given "a PATH without brew"
    original_path = ENV["PATH"]
    ENV["PATH"] = "/usr/bin:/bin"

    Expect "no prefix is found"
    Dev::ShadowenvPython.brew_prefix_for("python@3.12").nil? == true

    Cleanup
    ENV["PATH"] = original_path
  end

  test "brew_prefix_for returns the directory brew prints" do
    Given "a fake brew printing an existing directory"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    prefix = File.join(tmpdir, "opt", "python@3.12")
    FileUtils.mkdir_p(prefix)
    write_fake_brew(tmpdir, prefix: prefix)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "the printed prefix is returned"
    Dev::ShadowenvPython.brew_prefix_for("python@3.12") == prefix

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  test "brew_prefix_for returns nil when brew prints a nonexistent directory" do
    Given "a fake brew printing a directory that does not exist"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    write_fake_brew(tmpdir, prefix: File.join(tmpdir, "no-such-prefix"))
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    Expect "nil is returned"
    Dev::ShadowenvPython.brew_prefix_for("python@3.12").nil? == true

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end

  private

  # Writes an executable script and returns its path.
  def write_fake_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
    path
  end

  # A python stand-in whose `-m venv <dir>` materializes a minimal venv with a
  # working bin/python; any other invocation (the pip probes) succeeds.
  def write_venv_capable_python(dir)
    write_fake_executable(File.join(dir, "python"), <<~SCRIPT)
      #!/bin/sh
      if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
        mkdir -p "$3/bin"
        printf '#!/bin/sh\\nexit 0\\n' > "$3/bin/python"
        chmod 755 "$3/bin/python"
      fi
      exit 0
    SCRIPT
  end

  # A brew stand-in: `list` exits list_exit, `install` logs and exits
  # install_exit, `--prefix` prints the given prefix. Returns the log path.
  def write_fake_brew(dir, prefix:, list_exit: 0, install_exit: 0)
    log = File.join(dir, "invocations.log")
    write_fake_executable(File.join(dir, "brew"), <<~SCRIPT)
      #!/bin/sh
      echo "$@" >> "#{log}"
      case "$1" in
        list) exit #{list_exit} ;;
        install) exit #{install_exit} ;;
        --prefix) printf '%s\\n' "#{prefix}" ;;
      esac
      exit 0
    SCRIPT
    log
  end
end
