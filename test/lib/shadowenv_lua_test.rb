# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_lua"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvLuaTest < Minitest::Test
  test "provisioned? returns true when lisp file matches version" do
    Given
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_lua.lisp"),
      ShadowenvLua.generate_lua_lisp("5.1"),
    )

    Expect
    ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when no lisp file exists" do
    Given
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")

    Expect
    ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false for different version" do
    Given
    tmpdir = Dir.mktmpdir("shadowenv-lua-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_lua.lisp"),
      ShadowenvLua.generate_lua_lisp("5.4"),
    )

    Expect
    ShadowenvLua.provisioned?("5.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "generate_lua_lisp contains provide directive" do
    When
    result = ShadowenvLua.generate_lua_lisp("5.1")

    Then
    assert_includes result, '(provide "lua" "5.1")'
  end

  test "generate_lua_lisp sets LUA_PATH for lua_modules" do
    When
    result = ShadowenvLua.generate_lua_lisp("5.1")

    Then
    assert_includes result, "LUA_PATH"
    assert_includes result, "lua_modules"
  end

  test "generate_lua_lisp sets LUA_CPATH for lua_modules" do
    When
    result = ShadowenvLua.generate_lua_lisp("5.1")

    Then
    assert_includes result, "LUA_CPATH"
  end

  test "generate_lua_lisp prepends lua and luarocks to PATH" do
    When
    result = ShadowenvLua.generate_lua_lisp("5.1")

    Then
    assert_includes result, "lua@5.1"
    assert_includes result, "luarocks"
  end

  test "setup! writes lisp file and returns true" do
    Given
    tmpdir = Dir.mktmpdir("shadowenv-lua-setup-")

    When
    result = ShadowenvLua.setup!(lua_version: "5.1", project_root: tmpdir)

    Then
    _ * ShadowenvLua.method(:system) >> true
    result == true
    lisp_path = File.join(tmpdir, ".shadowenv.d", "510_lua.lisp")
    assert File.exist?(lisp_path)
    content = File.read(lisp_path)
    assert_includes content, '(provide "lua" "5.1")'

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
