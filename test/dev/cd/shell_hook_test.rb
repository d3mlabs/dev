# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Cd::ShellHookTest < Minitest::Test
  test "ensure! adds the zsh hook when missing" do
    Given "a zsh home with no .zshrc"
    tmpdir = Dir.mktmpdir("dev-cd-hook-")
    env = { "SHELL" => "/bin/zsh", "HOME" => tmpdir }

    When
    result = Dev::Cd::ShellHook.new(env:).ensure!

    Then
    result == :added
    zshrc = File.read(File.join(tmpdir, ".zshrc"))
    assert_includes zshrc, Dev::Cd::ShellHook::MARKER
    assert_includes zshrc, 'command dev cd --resolve'
    assert_includes zshrc, "builtin cd"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure! is idempotent for zsh" do
    Given "a zshrc that already has the hook"
    tmpdir = Dir.mktmpdir("dev-cd-hook-")
    env = { "SHELL" => "/bin/zsh", "HOME" => tmpdir }
    Dev::Cd::ShellHook.new(env:).ensure!
    before = File.read(File.join(tmpdir, ".zshrc"))

    When "ensuring again"
    result = Dev::Cd::ShellHook.new(env:).ensure!

    Then
    result == :already_present
    File.read(File.join(tmpdir, ".zshrc")) == before

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure! adds the bash hook to .bash_profile" do
    Given "a bash home"
    tmpdir = Dir.mktmpdir("dev-cd-hook-")
    env = { "SHELL" => "/bin/bash", "HOME" => tmpdir }

    When
    result = Dev::Cd::ShellHook.new(env:).ensure!

    Then
    result == :added
    profile = File.read(File.join(tmpdir, ".bash_profile"))
    assert_includes profile, Dev::Cd::ShellHook::MARKER
    assert_includes profile, "complete -F _dev dev"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure! adds the fish hook to config.fish" do
    Given "a fish home"
    tmpdir = Dir.mktmpdir("dev-cd-hook-")
    env = { "SHELL" => "/usr/local/bin/fish", "HOME" => tmpdir }

    When
    result = Dev::Cd::ShellHook.new(env:).ensure!

    Then
    result == :added
    config = File.read(File.join(tmpdir, ".config", "fish", "config.fish"))
    assert_includes config, Dev::Cd::ShellHook::MARKER
    assert_includes config, "command dev cd --resolve"

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure! returns false for unsupported shells" do
    Given "a plain sh"
    tmpdir = Dir.mktmpdir("dev-cd-hook-")
    env = { "SHELL" => "/bin/sh", "HOME" => tmpdir }

    Expect
    Dev::Cd::ShellHook.new(env:).ensure! == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end
end
