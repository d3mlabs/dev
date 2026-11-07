# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shell_rc_hook"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::ShellRcHookTest < Minitest::Test
  # ai-flow#116 / dev#483: the hook is a human-shell convenience, and an
  # agent run (ai-agent, no terminal) has no business writing a shell
  # profile — `shadowenv exec` is what a run uses. Off a tty the write is
  # a no-op; the posture is injected, never read from the test's own stdin.
  test "ensure_snippet off a tty is a no-op: no RC file is touched and the snippet stays absent" do
    Given "a zsh user with no .zshrc, headless"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home, interactive: false)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })

    Then "nothing is written"
    Dir.children(home).empty?
    !hook.snippet_present?(marker: "# my hook (added by dev)")

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet appends the marker and snippet to a fresh zshrc" do
    Given "a zsh user with no .zshrc"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home, interactive: true)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })

    Then "the snippet lands in .zshrc under its marker"
    content = File.read(File.join(home, ".zshrc"))
    assert_includes content, "# my hook (added by dev)"
    assert_includes content, "my_hook_line"
    hook.snippet_present?(marker: "# my hook (added by dev)")

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet is idempotent: a second run leaves the RC untouched" do
    Given "a zsh user whose .zshrc already carries the marker"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home, interactive: true)
    hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })
    before = File.read(File.join(home, ".zshrc"))

    When "we ensure the same snippet again"
    hook.ensure_snippet(marker: "# my hook (added by dev)", snippets: { zsh: "my_hook_line" })

    Then "nothing is appended"
    File.read(File.join(home, ".zshrc")) == before

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet honors extra present_markers (hand-installed hooks)" do
    Given "a zshrc with a hand-added hook line but no dev marker"
    home = Dir.mktmpdir("rc-hook-test-")
    File.write(File.join(home, ".zshrc"), 'eval "$(shadowenv init zsh)"')
    before = File.read(File.join(home, ".zshrc"))
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home, interactive: true)

    When "we ensure the snippet with the hook line as a present marker"
    hook.ensure_snippet(
      marker: "# Shadowenv (added by dev)",
      present_markers: ["shadowenv init"],
      snippets: { zsh: 'eval "$(shadowenv init zsh)"' },
    )

    Then "the hand install is recognized, not re-appended"
    File.read(File.join(home, ".zshrc")) == before
    hook.snippet_present?(marker: "# Shadowenv (added by dev)", present_markers: ["shadowenv init"])

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "snippet_present? is false before the ensure and does not create the RC" do
    Given "a zsh user with no .zshrc"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/zsh", home: home, interactive: true)

    Expect "no snippet, no file"
    !hook.snippet_present?(marker: "# my hook")
    Dir.children(home).empty?

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet raises UnsupportedShellError for an unsupported shell" do
    Given "a user on plain sh"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/sh", home: home, interactive: true)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { zsh: "line" })

    Then "the install is refused, naming the supported set, and no RC file is created"
    e = raises Dev::ShellRcHook::UnsupportedShellError
    e.message.include?("/bin/sh")
    e.message.include?("zsh, bash, fish")
    Dir.children(home).empty?

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet off a tty on an unsupported shell is still a silent no-op" do
    Given "a headless run whose $SHELL is plain sh (a runner job)"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/sh", home: home, interactive: false)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { zsh: "line" })

    Then "nothing is raised and nothing is written"
    Dir.children(home).empty?

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "snippet_present? raises UnsupportedShellError for an unsupported shell" do
    Given "a user on plain sh"
    hook = Dev::ShellRcHook.new(shell: "/bin/sh", home: Dir.tmpdir, interactive: true)

    When "we ask whether the snippet is present"
    hook.snippet_present?(marker: "# my hook")

    Then
    raises Dev::ShellRcHook::UnsupportedShellError
  end

  test "bash resolves to .bash_profile by default" do
    Given "a bash user with neither RC file"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/bin/bash", home: home, interactive: true)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { bash: "bash_line" })

    Then "it lands in .bash_profile"
    assert_includes File.read(File.join(home, ".bash_profile")), "bash_line"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "bash falls back to an existing .bashrc when .bash_profile is absent" do
    Given "a bash user with only a .bashrc"
    home = Dir.mktmpdir("rc-hook-test-")
    File.write(File.join(home, ".bashrc"), "# existing bashrc\n")
    hook = Dev::ShellRcHook.new(shell: "/bin/bash", home: home, interactive: true)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { bash: "bash_line" })

    Then "it appends to .bashrc"
    assert_includes File.read(File.join(home, ".bashrc")), "bash_line"
    !File.exist?(File.join(home, ".bash_profile"))

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "fish installs into ~/.config/fish/config.fish, creating the directory" do
    Given "a fish user with no config directory"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/usr/local/bin/fish", home: home, interactive: true)

    When "we ensure a snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { fish: "fish_line" })

    Then "the config file is created with the snippet"
    assert_includes File.read(File.join(home, ".config", "fish", "config.fish")), "fish_line"

    Cleanup
    FileUtils.rm_rf(home)
  end

  test "ensure_snippet raises UnsupportedShellError when the snippet set has nothing for the shell" do
    Given "a fish user and a zsh-only snippet set"
    home = Dir.mktmpdir("rc-hook-test-")
    hook = Dev::ShellRcHook.new(shell: "/usr/local/bin/fish", home: home, interactive: true)

    When "we ensure the snippet"
    hook.ensure_snippet(marker: "# my hook", snippets: { zsh: "line" })

    Then "the install is refused, naming the shells the snippet set covers"
    e = raises Dev::ShellRcHook::UnsupportedShellError
    e.message.include?("supported: zsh")
    Dir.children(home).empty?

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
