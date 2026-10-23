# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/brew_env"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class BrewEnvTest < Minitest::Test
  test "user_file is ~/.homebrew/brew.env by default" do
    Expect
    Dev::BrewEnv.user_file(env: { "HOME" => "/Users/me" }) == Pathname("/Users/me/.homebrew/brew.env")
  end

  test "user_file follows XDG_CONFIG_HOME when set" do
    Expect
    Dev::BrewEnv.user_file(env: { "HOME" => "/Users/me", "XDG_CONFIG_HOME" => "/Users/me/.config" }) ==
      Pathname("/Users/me/.config/homebrew/brew.env")
  end

  test "no_cleanup_formulae is empty when the file does not exist" do
    Given "no brew.env"
    dir = Dir.mktmpdir("brew-env-test-")

    Expect
    Dev::BrewEnv.new(path: Pathname(dir) / "brew.env").no_cleanup_formulae == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "no_cleanup_formulae reads the list, quoted or bare" do
    Given "a brew.env with the key quoted"
    dir = Dir.mktmpdir("brew-env-test-")
    path = Pathname(dir) / "brew.env"
    path.write(%(HOMEBREW_NO_ENV_HINTS=1\nHOMEBREW_NO_CLEANUP_FORMULAE="cmake, llvm@18"\n))

    Expect
    Dev::BrewEnv.new(path:).no_cleanup_formulae == ["cmake", "llvm@18"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "retain! creates the file with the key when none exists" do
    Given "no brew.env, and a config dir that does not exist yet"
    dir = Dir.mktmpdir("brew-env-test-")
    path = Pathname(dir) / "homebrew" / "brew.env"

    When "retaining two formulae"
    changed = Dev::BrewEnv.new(path:).retain!(["cmake", "llvm@18"])

    Then "the file holds exactly that key, and the call reports a change"
    changed == true
    path.read == "HOMEBREW_NO_CLEANUP_FORMULAE=cmake,llvm@18\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "retain! adds to an existing list and preserves every other line" do
    Given "a brew.env with other settings and a partial list"
    dir = Dir.mktmpdir("brew-env-test-")
    path = Pathname(dir) / "brew.env"
    path.write("# my settings\nHOMEBREW_NO_ENV_HINTS=1\nHOMEBREW_NO_CLEANUP_FORMULAE=cmake\nHOMEBREW_CASK_OPTS=--no-quarantine\n")

    When "retaining a formula already listed and a new one"
    changed = Dev::BrewEnv.new(path:).retain!(["cmake", "pwsh@7.4.0"])

    Then "the key gains the new name in place; nothing else moves"
    changed == true
    path.read == "# my settings\nHOMEBREW_NO_ENV_HINTS=1\nHOMEBREW_NO_CLEANUP_FORMULAE=cmake,pwsh@7.4.0\nHOMEBREW_CASK_OPTS=--no-quarantine\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "retain! never removes a name another project may rely on" do
    Given "a list with a formula this project does not lock"
    dir = Dir.mktmpdir("brew-env-test-")
    path = Pathname(dir) / "brew.env"
    path.write("HOMEBREW_NO_CLEANUP_FORMULAE=cmake,ninja\n")

    When "retaining only cmake"
    changed = Dev::BrewEnv.new(path:).retain!(["cmake"])

    Then "ninja stays, and nothing was written"
    changed == false
    path.read == "HOMEBREW_NO_CLEANUP_FORMULAE=cmake,ninja\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "retain! raises WriteError when the file cannot be written" do
    Given "a brew.env path under a file, not a directory"
    dir = Dir.mktmpdir("brew-env-test-")
    blocker = Pathname(dir) / "homebrew"
    blocker.write("")

    When "retaining"
    Dev::BrewEnv.new(path: blocker / "brew.env").retain!(["cmake"])

    Then
    raises Dev::BrewEnv::WriteError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
