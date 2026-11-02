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


  test "venv_path is #{expected} on the #{side} side of the build container" do
    Expect
    Dev::ShadowenvPython.venv_path(Pathname("/tmp/proj"), inside: inside) == Pathname("/tmp/proj") / expected

    Where
    side        | inside | expected
    "host"      | false  | ".venv"
    "container" | true   | ".venv-container"
  end

  test "venv_path reads the side from the inside marker when none is given" do
    Given "a process carrying the inside marker"
    original = ENV[Dev::ContainerContext::MARKER]
    ENV[Dev::ContainerContext::MARKER] = "1"

    When "resolving the venv path without naming a side"
    path = Dev::ShadowenvPython.venv_path(Pathname("/tmp/proj"))

    Then "it is the container's"
    path == Pathname("/tmp/proj") / Dev::ShadowenvPython::CONTAINER_VENV_DIR

    Cleanup
    original ? ENV[Dev::ContainerContext::MARKER] = original : ENV.delete(Dev::ContainerContext::MARKER)
  end

  test "activate! inside the build container builds its own venv and leaves the host's alone" do
    Given "a project whose host side already has its venv, and a dev running inside the container"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    host_venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(host_venv, "bin"))
    File.write(File.join(host_venv, "pyvenv.cfg"), "home = /opt/homebrew/opt/python@3.12/bin\nversion = 3.12.8\n")
    original = ENV[Dev::ContainerContext::MARKER]
    ENV[Dev::ContainerContext::MARKER] = "1"

    When "activating twice inside"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "one venv was built, at the container's path; the host's cfg is untouched; the container lisp activates the container's venv"
    File.read(log).lines.select { |line| line.start_with?("-m venv") } == ["-m venv #{File.join(tmpdir, ".venv-container")}\n"]
    File.executable?(File.join(tmpdir, ".venv-container", "bin", "python")) == true
    File.read(File.join(host_venv, "pyvenv.cfg")) == "home = /opt/homebrew/opt/python@3.12/bin\nversion = 3.12.8\n"
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "540_python_container.lisp"))
    lisp.include?(%((env/set "VIRTUAL_ENV" "#{File.join(tmpdir, ".venv-container")}")))
    !File.exist?(File.join(tmpdir, ".shadowenv.d", "540_python.lisp"))

    Cleanup
    original ? ENV[Dev::ContainerContext::MARKER] = original : ENV.delete(Dev::ContainerContext::MARKER)
    FileUtils.rm_rf(tmpdir)
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

  test "activate! pins the venv to the keg: its interpreter and home resolve inside the keg, not through brew's opt link" do
    Given "a locked keg beside a newer one that brew's opt link points at"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    newer_keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.9"
    newer_log = write_keg_python(newer_keg)
    log = write_keg_python(keg)
    venv = Pathname(tmpdir) / ".venv"

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "every interpreter name in the venv is the keg's, pyvenv.cfg says so, and the newer keg was never run"
    File.readlink(venv / "bin" / "python3.12") == (keg / "bin" / "python3.12").to_s
    File.realpath(venv / "bin" / "python") == File.realpath(keg / "bin" / "python3.12")
    File.realpath(venv / "bin" / "python3") == File.realpath(keg / "bin" / "python3.12")
    File.read(venv / "pyvenv.cfg").include?("home = #{keg / "bin"}\n")
    File.read(log).lines.any? { |line| line.start_with?("-m pip --version") }
    !File.exist?(newer_log)

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
    File.read(File.join(venv, "pyvenv.cfg")).include?("home = #{keg / "bin"}\n")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! rebuilds a venv whose home goes through the opt link: built before dev pinned venvs to the keg, it runs whatever keg brew links" do
    Given "a venv built by the locked 3.12.8 keg, whose cfg paths all go through an opt link that now points at a newer keg"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), <<~CFG)
      home = #{File.join(tmpdir, "opt", "python@3.12", "bin")}
      include-system-site-packages = false
      version = 3.12.8
      executable = #{File.join(tmpdir, "Cellar", "python@3.12", "3.12.9", "Frameworks", "Python.framework", "Versions", "3.12", "bin", "python3.12")}
      command = #{File.join(tmpdir, "opt", "python@3.12", "bin", "python3.12")} -m venv #{venv}
    CFG

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the venv was rebuilt on the locked keg"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! keeps a venv pinned to the keg that records only home and version" do
    Given "a venv whose pyvenv.cfg has home = the keg's bin and the locked version"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = #{keg / "bin"}\nversion = 3.12.8\n")

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the keg's interpreter was never asked to build a venv"
    !File.exist?(log)

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! rebuilds a venv built by another version of the same minor, whose cfg otherwise reads the same" do
    Given "a venv pinned to a 3.12.7 keg of this prefix, the lock now pinning 3.12.8"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = #{File.join(tmpdir, "Cellar", "python@3.12", "3.12.7", "bin")}\nversion = 3.12.7\n")

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the venv was rebuilt on the locked keg"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! rebuilds a venv of the locked version built under another brew prefix" do
    Given "a venv pinned to a 3.12.8 keg of a Linuxbrew prefix (a checkout copied from another machine), the project now activating on this prefix's keg"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = /home/linuxbrew/.linuxbrew/Cellar/python@3.12/3.12.8_1/bin\nversion = 3.12.8\n")

    When "activating"
    Dev::ShadowenvPython.activate!(keg: keg, version: "3.12.8", project_root: Pathname(tmpdir))

    Then "the venv was rebuilt on the locked keg"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1

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

  # A brew keg's bin/python3.12 stand-in under a prefix laid out like
  # brew's (`<prefix>/Cellar/<formula>/<version>`, with `<prefix>/opt/<formula>`
  # linked to the keg unless the test linked it elsewhere first): logs every
  # invocation; `-m venv <dir>` materializes a minimal venv laid out as
  # Python's venv module lays one out on a brew Python — `bin/python3.12`
  # a symlink to the opt link's interpreter, `python` and `python3` relative
  # symlinks to it, and a pyvenv.cfg whose `home` is the opt link's bin, not
  # the keg's. Returns the log path.
  def write_keg_python(keg)
    log = File.join(keg, "invocations.log")
    FileUtils.mkdir_p(File.join(keg, "bin"))
    opt = keg.parent.parent.parent / "opt" / keg.parent.basename
    FileUtils.mkdir_p(opt.dirname)
    FileUtils.ln_s(keg, opt) unless opt.symlink?
    script = [
      "#!/bin/sh",
      "echo \"$@\" >> \"#{log}\"",
      "if [ \"$1\" = \"-m\" ] && [ \"$2\" = \"venv\" ]; then",
      "  mkdir -p \"$3/bin\"",
      "  ln -s \"#{opt / "bin" / "python3.12"}\" \"$3/bin/python3.12\"",
      "  ln -s python3.12 \"$3/bin/python\"",
      "  ln -s python3.12 \"$3/bin/python3\"",
      "  printf 'home = %s\\nversion = 3.12.8\\n' \"#{opt / "bin"}\" > \"$3/pyvenv.cfg\"",
      "fi",
      "exit 0",
    ].join("\n")
    # brew\x27s python@X.Y keg ships bin/pythonX.Y only; the bare python3 lives
    # in libexec/bin and in the opt link, neither of which is the keg.
    write_fake_executable(File.join(keg, "bin", "python3.12"), script)
    log
  end
end
