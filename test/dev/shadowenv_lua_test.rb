# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shadowenv_lua"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvLuaTest < Minitest::Test
  test "provisioned? returns true when lisp file matches version" do
    Given "a 510_lua.lisp provisioned for 5.1"
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_lua.lisp"),
      Dev::ShadowenvLua.generate_lua_lisp("5.1"),
    )

    Expect "provisioned? returns true"
    Dev::ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when no lisp file exists" do
    Given "an empty project root"
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")

    Expect "provisioned? returns false"
    Dev::ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false for different version" do
    Given "a 510_lua.lisp provisioned for 5.4"
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_lua.lisp"),
      Dev::ShadowenvLua.generate_lua_lisp("5.4"),
    )

    Expect "provisioned? returns false for mismatched version"
    Dev::ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "generate_lua_lisp contains provide directive" do
    When "generating lisp for 5.1"
    result = Dev::ShadowenvLua.generate_lua_lisp("5.1")

    Then "the lisp includes the provide directive"
    assert_includes result, '(provide "lua" "5.1")'
  end

  test "generate_lua_lisp sets LUA_PATH for lua_modules" do
    When "generating lisp for 5.1"
    result = Dev::ShadowenvLua.generate_lua_lisp("5.1")

    Then "LUA_PATH references lua_modules"
    assert_includes result, "LUA_PATH"
    assert_includes result, "lua_modules"
  end

  test "generate_lua_lisp sets LUA_CPATH for lua_modules" do
    When "generating lisp for 5.1"
    result = Dev::ShadowenvLua.generate_lua_lisp("5.1")

    Then "LUA_CPATH is configured"
    assert_includes result, "LUA_CPATH"
  end

  test "generate_lua_lisp prepends lua and luarocks to PATH" do
    When "generating lisp for 5.1"
    result = Dev::ShadowenvLua.generate_lua_lisp("5.1")

    Then "PATH includes lua formula and luarocks"
    assert_includes result, "lua@5.1"
    assert_includes result, "luarocks"
  end

  test "setup! writes lisp file and returns true" do
    Given "a temporary project directory"
    tmpdir = Dir.mktmpdir("shadowenv-lua-setup-")

    When "running setup! with all system calls stubbed"
    result = Dev::ShadowenvLua.setup!(lua_version: "5.1", project_root: tmpdir)

    Then "it writes the lisp file and returns true"
    _ * Kernel.system >> true
    result == true
    lisp_path = File.join(tmpdir, ".shadowenv.d", "510_lua.lisp")
    assert File.exist?(lisp_path)
    content = File.read(lisp_path)
    assert_includes content, '(provide "lua" "5.1")'

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "setup! raises BrewInstallError when lua formula install fails" do
    Given "a temporary project directory"
    tmpdir = Dir.mktmpdir("shadowenv-lua-setup-")

    When "brew list returns false and brew install also fails"
    error = assert_raises(Dev::ShadowenvLua::BrewInstallError) do
      Dev::ShadowenvLua.setup!(lua_version: "5.1", project_root: tmpdir)
    end

    Then "the error mentions the failing formula"
    _ * Kernel.system >> false
    error.message.include?("lua@5.1")

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_homebrew_lua! raises BrewInstallError when the luarocks install fails" do
    Given "a fake brew with lua installed but luarocks missing and uninstallable"
    tmpdir = Dir.mktmpdir("fake-brew-lua-")
    fake_brew = File.join(tmpdir, "brew")
    File.write(fake_brew, <<~SH)
      #!/bin/sh
      case "$1 $2" in
        "list lua@5.1") exit 0 ;;
        "list luarocks") exit 1 ;;
        "install luarocks") exit 1 ;;
      esac
      exit 0
    SH
    FileUtils.chmod(0o755, fake_brew)
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{tmpdir}:/usr/bin:/bin"

    When "ensuring the Homebrew lua toolchain"
    error = assert_raises(Dev::ShadowenvLua::BrewInstallError) do
      Dev::ShadowenvLua.ensure_homebrew_lua!("5.1")
    end

    Then "the error names the failing luarocks install"
    error.message.include?("luarocks")

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(tmpdir)
  end
end
