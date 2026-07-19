# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "dev/shell_rc_hook"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Cd::HookInstallerTest < Minitest::Test
  test "installs the zsh wrapper function and completer into .zshrc" do
    Given "a zsh user with no .zshrc"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/bin/zsh", home: home)

    When "we ensure the hook"
    result = installer.ensure_installed

    Then "the wrapper, completer and dev-scoped menu-select are installed"
    result == :added
    content = File.read(File.join(home, ".zshrc"))
    assert_includes content, "# dev cd (added by dev)"
    assert_includes content, 'command dev cd --resolve "$@"'
    assert_includes content, "builtin cd"
    assert_includes content, "compadd -U"
    assert_includes content, "zstyle ':completion:*:*:dev:*' menu select"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "zsh completer registration is guarded on compsys being initialized" do
    Given "a zsh user"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/bin/zsh", home: home)

    When "we ensure the hook"
    installer.ensure_installed

    Then "compdef is only used when it exists"
    content = File.read(File.join(home, ".zshrc"))
    assert_includes content, "compdef >/dev/null"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "re-running the install does not duplicate RC lines" do
    Given "a zsh user with the hook already installed"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/bin/zsh", home: home)
    installer.ensure_installed
    before = File.read(File.join(home, ".zshrc"))

    When "we ensure the hook again"
    result = installer.ensure_installed

    Then "nothing changes"
    result == :already_present
    File.read(File.join(home, ".zshrc")) == before

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "installs the bash wrapper with direct COMPREPLY (no compgen filtering)" do
    Given "a bash user"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/bin/bash", home: home)

    When "we ensure the hook"
    result = installer.ensure_installed

    Then "the wrapper and completer land in .bash_profile"
    result == :added
    content = File.read(File.join(home, ".bash_profile"))
    assert_includes content, 'command dev cd --resolve "$@"'
    assert_includes content, "COMPREPLY=($(command dev cd --candidates"
    assert_includes content, "complete -F _dev_cd_completion dev"
    refute_includes content, "compgen -W"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "installs the fish wrapper function and completer into config.fish" do
    Given "a fish user"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/usr/local/bin/fish", home: home)

    When "we ensure the hook"
    result = installer.ensure_installed

    Then "the wrapper and completer land in config.fish"
    result == :added
    content = File.read(File.join(home, ".config", "fish", "config.fish"))
    assert_includes content, "function dev"
    assert_includes content, "command dev cd --resolve $argv"
    assert_includes content, "complete -c dev"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "an unsupported shell refuses the install" do
    Given "a plain sh user"
    home = Dir.mktmpdir("cd-hook-test-")
    installer = build_installer(shell: "/bin/sh", home: home)

    Expect "the install is refused"
    installer.ensure_installed == false

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "the dev cd hook coexists with the shadowenv hook in the same RC" do
    Given "a zsh user with the shadowenv hook already installed"
    home = Dir.mktmpdir("cd-hook-test-")
    rc_hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home)
    rc_hook.ensure_snippet(marker: "# Shadowenv (added by dev)", snippets: { zsh: 'eval "$(shadowenv init zsh)"' })
    installer = Dev::Cd::HookInstaller.new(rc_hook: rc_hook)

    When "we ensure the dev cd hook"
    result = installer.ensure_installed

    Then "both snippets are present with their own markers"
    result == :added
    content = File.read(File.join(home, ".zshrc"))
    assert_includes content, "# Shadowenv (added by dev)"
    assert_includes content, "# dev cd (added by dev)"

    Cleanup
    FileUtils.rm_rf(home)
  end

  private

  def build_installer(shell:, home:)
    Dev::Cd::HookInstaller.new(rc_hook: Dev::ShellRcHook.new(shell: shell, home: home))
  end
end
