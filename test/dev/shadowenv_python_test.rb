# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/local_store"
require "dev/shadowenv_python"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvPythonTest < Minitest::Test
  # The project every test activates for: its dev.yml name, the venv's key in the store.
  PROJECT_NAME = "proj"

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

  test "venv_key names the store venv by project, #{side} side and the keg's full version" do
    When "keying a project's venv on a keg brew named with a revision"
    key = Dev::ShadowenvPython.venv_key(
      project_name: "cellbound-3d", keg: Pathname("/opt/homebrew/Cellar/python@3.12/3.12.8_1"), inside: inside,
    )

    Then "the base is the project's under the venv root, the platform the side, the version the keg's, under the venv marker"
    key.base == "~/.dev/venv/cellbound-3d"
    key.platform == side
    key.version == "3.12.8_1"
    key.marker == Dev::ShadowenvPython::MARKER_FILE

    Where
    side        | inside
    "host"      | false
    "container" | true
  end

  test "activate! builds the venv in the store on the keg's pythonX.Y, links the project's .venv at it and writes the lisp" do
    Given "a project root, the locked Python's keg and an empty store"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    stored = stored_venv(tmpdir, "host", "3.12.8")

    When "activating"
    activate!(tmpdir, keg)

    Then "the venv was built by the keg's interpreter at its store path with pip and the marker; .venv links at it; the lisp activates the store path"
    File.read(log).lines.first.start_with?("-m venv #{stored}")
    File.read(log).lines.any? { |line| line.start_with?("-m pip --version") }
    File.executable?(File.join(stored, "bin", "python")) == true
    File.read(File.join(stored, Dev::ShadowenvPython::MARKER_FILE)) == "3.12.8"
    File.readlink(File.join(tmpdir, ".venv")) == stored.to_s
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "540_python.lisp"))
    lisp.include?('(provide "python" "3.12.8")')
    lisp.include?(%((env/set "VIRTUAL_ENV" "#{stored}")))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! builds once: a second activation finds the store venv by its marker and runs no interpreter" do
    Given "a project whose venv a first activation built"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    activate!(tmpdir, keg)
    File.delete(log)

    When "activating again"
    activate!(tmpdir, keg)

    Then "neither -m venv nor pip ran, and the link still points at the store venv"
    !File.exist?(log)
    File.readlink(File.join(tmpdir, ".venv")) == stored_venv(tmpdir, "host", "3.12.8").to_s

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! wipes a store venv whose build never finished and rebuilds it" do
    Given "a store venv directory with no marker: a build the last activation did not complete"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    stored = stored_venv(tmpdir, "host", "3.12.8")
    FileUtils.mkdir_p(stored / "bin")
    File.write(stored / "leftover", "")

    When "activating"
    activate!(tmpdir, keg)

    Then "the venv was built afresh at the same path"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1
    !File.exist?(stored / "leftover")
    File.file?(stored / Dev::ShadowenvPython::MARKER_FILE)

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "two worktrees of one project share one store venv per side" do
    Given "two checkouts of the same project against one store"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    first = File.join(tmpdir, "worktrees", "main")
    second = File.join(tmpdir, "worktrees", "feature")
    FileUtils.mkdir_p([first, second])

    When "each activates"
    activate!(first, keg, data_root: tmpdir)
    activate!(second, keg, data_root: tmpdir)

    Then "one venv was built, and both checkouts' .venv link at it"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1
    File.readlink(File.join(first, ".venv")) == stored_venv(tmpdir, "host", "3.12.8").to_s
    File.readlink(File.join(second, ".venv")) == stored_venv(tmpdir, "host", "3.12.8").to_s

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! inside the build container builds the container's venv and leaves the host's alone" do
    Given "a project whose host side already has its venv, and a dev running inside the container"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    host_venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(host_venv, "bin"))
    File.write(File.join(host_venv, "pyvenv.cfg"), "home = /opt/homebrew/opt/python@3.12/bin\nversion = 3.12.8\n")
    stored = stored_venv(tmpdir, "container", "3.12.8")
    original = ENV[Dev::ContainerContext::MARKER]
    ENV[Dev::ContainerContext::MARKER] = "1"

    When "activating twice inside"
    activate!(tmpdir, keg)
    activate!(tmpdir, keg)

    Then "one venv was built, on the container side of the store; .venv-container links at it; the host's cfg is untouched; the container lisp activates the store venv"
    File.read(log).lines.select { |line| line.start_with?("-m venv") } == ["-m venv #{stored}\n"]
    File.readlink(File.join(tmpdir, ".venv-container")) == stored.to_s
    File.read(File.join(host_venv, "pyvenv.cfg")) == "home = /opt/homebrew/opt/python@3.12/bin\nversion = 3.12.8\n"
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "540_python_container.lisp"))
    lisp.include?(%((env/set "VIRTUAL_ENV" "#{stored}")))
    !File.exist?(File.join(tmpdir, ".shadowenv.d", "540_python.lisp"))

    Cleanup
    original ? ENV[Dev::ContainerContext::MARKER] = original : ENV.delete(Dev::ContainerContext::MARKER)
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! pins the venv to the keg: its interpreter and home resolve inside the keg, not through brew's opt link" do
    Given "a locked keg beside a newer one that brew's opt link points at"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    newer_keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.9"
    newer_log = write_keg_python(newer_keg)
    log = write_keg_python(keg)
    venv = stored_venv(tmpdir, "host", "3.12.8")

    When "activating"
    activate!(tmpdir, keg)

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

  test "activate! keys the venv by the keg brew named, revision included, so a rebuilt keg is a new venv" do
    Given "a venv built on the 3.12.8 keg, the keg now reinstalled as 3.12.8_1"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    write_keg_python(keg)
    activate!(tmpdir, keg)
    revised_keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(revised_keg)

    When "activating on the revised keg"
    activate!(tmpdir, revised_keg)

    Then "a venv was built under the revised keg's version and the link moved to it"
    File.read(log).lines.first.start_with?("-m venv #{stored_venv(tmpdir, "host", "3.12.8_1")}")
    File.readlink(File.join(tmpdir, ".venv")) == stored_venv(tmpdir, "host", "3.12.8_1").to_s
    File.directory?(stored_venv(tmpdir, "host", "3.12.8"))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! keeps a plain-directory venv built on the locked keg, from before venvs lived in the store" do
    Given "a venv in the project whose pyvenv.cfg has home = the keg's bin and the locked version"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = #{keg / "bin"}\nversion = 3.12.8\n")

    When "activating"
    activate!(tmpdir, keg)

    Then "the keg's interpreter was never run, the directory is still a directory, the lisp activates it, and the store holds nothing"
    !File.exist?(log)
    File.directory?(venv) && !File.symlink?(venv)
    File.read(File.join(tmpdir, ".shadowenv.d", "540_python.lisp")).include?(%((env/set "VIRTUAL_ENV" "#{venv}")))
    !File.exist?(File.join(tmpdir, "venv"))

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! replaces a plain-directory venv built on another interpreter with the link into the store" do
    Given "a venv in the project built on some other Python"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), "home = /elsewhere/python@3.11/bin\nversion = 3.11.9\n")

    When "activating twice"
    activate!(tmpdir, keg)
    activate!(tmpdir, keg)

    Then "the first activation built the venv in the store and linked .venv at it; the second left both alone"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1
    File.symlink?(venv)
    File.readlink(venv) == stored_venv(tmpdir, "host", "3.12.8").to_s
    File.read(stored_venv(tmpdir, "host", "3.12.8") / "pyvenv.cfg").include?("home = #{keg / "bin"}\n")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! replaces a plain-directory venv #{built_how}" do
    Given "a venv in the project with that pyvenv.cfg"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8_1"
    log = write_keg_python(keg)
    venv = File.join(tmpdir, ".venv")
    FileUtils.mkdir_p(File.join(venv, "bin"))
    write_fake_executable(File.join(venv, "bin", "python"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(venv, "pyvenv.cfg"), cfg.call(tmpdir))

    When "activating"
    activate!(tmpdir, keg)

    Then "the venv was built in the store and .venv links at it"
    File.read(log).lines.count { |line| line.start_with?("-m venv") } == 1
    File.readlink(venv) == stored_venv(tmpdir, "host", "3.12.8_1").to_s

    Cleanup
    FileUtils.rm_rf(tmpdir)

    Where
    built_how | cfg
    "whose home goes through the opt link: built before dev pinned venvs to the keg" | ->(dir) { "home = #{File.join(dir, "opt", "python@3.12", "bin")}\nversion = 3.12.8\n" }
    "built by another version of the same minor, whose cfg otherwise reads the same" | ->(dir) { "home = #{File.join(dir, "Cellar", "python@3.12", "3.12.7", "bin")}\nversion = 3.12.7\n" }
    "of the locked version built under another brew prefix (a checkout copied from another machine)" | ->(_dir) { "home = /home/linuxbrew/.linuxbrew/Cellar/python@3.12/3.12.8_1/bin\nversion = 3.12.8\n" }
  end

  test "activate! raises when the keg's pythonX.Y cannot build the venv, and publishes nothing" do
    Given "a keg whose interpreter fails -m venv"
    tmpdir = Dir.mktmpdir("shadowenv-python-test-")
    keg = Pathname(tmpdir) / "Cellar" / "python@3.12" / "3.12.8"
    FileUtils.mkdir_p(keg / "bin")
    write_fake_executable((keg / "bin" / "python3.12").to_s, "#!/bin/sh\nexit 1\n")

    When "activating"
    activate!(tmpdir, keg)

    Then "the error names the failed venv creation, the store venv carries no marker and the project has no link"
    error = raises Dev::ShadowenvPython::VenvError
    error.message.include?("-m venv")
    !File.exist?(stored_venv(tmpdir, "host", "3.12.8") / Dev::ShadowenvPython::MARKER_FILE)
    !File.exist?(File.join(tmpdir, ".venv"))

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

  # Activate the keg's Python for the project at `project_root`, as the
  # brew integration does, against a store rooted at `data_root` (the
  # project root by default: one tmpdir holds the Cellar, the project and
  # the store).
  def activate!(project_root, keg, data_root: project_root)
    Dev::ShadowenvPython.activate!(
      keg: keg,
      version: keg.basename.to_s.sub(/_\d+\z/, ""),
      project_root: Pathname(project_root),
      project_name: PROJECT_NAME,
      store: Dev::Deps::LocalStore.new(data_root: data_root.to_s),
    )
  end

  # Where the store rooted at `data_root` homes the project's venv for one
  # side of the build container on one keg.
  def stored_venv(data_root, side, keg_version)
    Pathname(data_root) / "venv" / PROJECT_NAME / side / keg_version
  end

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
