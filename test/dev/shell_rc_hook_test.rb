# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shell_rc_hook"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::ShellRcHookTest < Minitest::Test
  test "ensure_snippet appends the marker and snippet to a fresh zshrc" do
    Given "a zsh user with no .zshrc"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home)

    When "we ensure a snippet"
    result = hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })

    Then "the snippet lands in .zshrc under its marker"
    result == :added
    content = File.read(File.join(home, ".zshrc"))
    assert_includes content, "# my hook (added by dev)"
    assert_includes content, "my_hook_line"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet is idempotent: a second run reports already_present" do
    Given "a zsh user whose .zshrc already carries the marker"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home)
    hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })
    before = File.read(File.join(home, ".zshrc"))

    When "we ensure the same snippet again"
    result = hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })

    Then "nothing is appended"
    result == :already_present
    File.read(File.join(home, ".zshrc")) == before

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet honors extra present_markers (hand-installed hooks)" do
    Given "a zshrc with a hand-added hook line but no dev marker"
    home = Dir.mktmpdir("rc-hook-test-")
    File.write(File.join(home, ".zshrc"), 'eval "$(shadowenv init zsh)"')
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home)

    When "we ensure the snippet with the hook line as a present marker"
    result = hook.ensure_snippet(
      marker: "# Shadowenv (added by dev)",
      present_markers: ["shadowenv init"],
      snippets: { zsh: 'eval "$(shadowenv init zsh)"' },
    )

    Then "the hand install is recognized, not re-appended"
    result == :already_present

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet returns false for an unsupported shell" do
    Given "a user on plain sh"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/sh", home: home)

    When "we ensure a snippet"
    result = hook.ensure_snippet(marker: "# my hook", snippets: { zsh: "line" })

    Then "the install is refused and no RC file is created"
    result == false
    Dir.children(home).empty?

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "bash resolves to .bash_profile by default" do
    Given "a bash user with neither RC file"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/bash", home: home)

    When "we ensure a snippet"
    result = hook.ensure_snippet(marker: "# my hook", snippets: { bash: "bash_line" })

    Then "it lands in .bash_profile"
    result == :added
    assert_includes File.read(File.join(home, ".bash_profile")), "bash_line"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "bash falls back to an existing .bashrc when .bash_profile is absent" do
    Given "a bash user with only a .bashrc"
    home = Dir.mktmpdir("rc-hook-test-")
    File.write(File.join(home, ".bashrc"), "# existing bashrc\n")
    hook = Dev::ShellRcHook.new(shell: "/bin/bash", home: home)

    When "we ensure a snippet"
    result = hook.ensure_snippet(marker: "# my hook", snippets: { bash: "bash_line" })

    Then "it appends to .bashrc"
    result == :added
    assert_includes File.read(File.join(home, ".bashrc")), "bash_line"
    !File.exist?(File.join(home, ".bash_profile"))

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "fish installs into ~/.config/fish/config.fish, creating the directory" do
    Given "a fish user with no config directory"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/usr/local/bin/fish", home: home)

    When "we ensure a snippet"
    result = hook.ensure_snippet(marker: "# my hook", snippets: { fish: "fish_line" })

    Then "the config file is created with the snippet"
    result == :added
    assert_includes File.read(File.join(home, ".config", "fish", "config.fish")), "fish_line"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet returns false when the shell has no snippet" do
    Given "a fish user and a zsh-only snippet set"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/usr/local/bin/fish", home: home)

    When "we ensure the snippet"
    result = hook.ensure_snippet(marker: "# my hook", snippets: { zsh: "line" })

    Then "the install is refused"
    result == false

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "shell_kind detects #{expected} from #{shell}" do
    Given "a hook for the shell"
    hook = Dev::ShellRcHook.new(shell: shell, home: Dir.tmpdir)

    Expect "the kind is detected"
    hook.shell_kind == expected

    Where
    shell                  | expected
    "/bin/zsh"             | :zsh
    "/opt/homebrew/bin/zsh" | :zsh
    "/bin/bash"            | :bash
    "/usr/local/bin/fish"  | :fish
  end

  test "shell_kind is nil for an unsupported shell" do
    Given "a hook for plain sh"
    hook = Dev::ShellRcHook.new(shell: "/bin/sh", home: Dir.tmpdir)

    Expect "no kind is detected"
    hook.shell_kind.nil?
  end
end
