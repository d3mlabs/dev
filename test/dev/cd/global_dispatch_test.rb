# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "tmpdir"
require "fileutils"
require "open3"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cd::GlobalDispatchTest < Minitest::Test
  DEV_BIN = File.expand_path("../../../bin/dev", __dir__)

  # @param root [String]
  # @param relative [String]
  # @return [Pathname]
  def make_git_repo(root, relative)
    path = Pathname(root) / relative
    FileUtils.mkdir_p(path)
    FileUtils.mkdir_p(path / ".git")
    path
  end

  test "dev cd --resolve works from a directory with no dev.yml" do
    Given "a temp cwd without dev.yml and a fake DEV_CD_ROOT"
    src = Dir.mktmpdir("dev-cd-src-")
    cwd = Dir.mktmpdir("dev-cd-cwd-")
    expected = make_git_repo(src, "github.com/d3mlabs/widgets")
    env = ENV.to_h.merge("DEV_CD_ROOT" => src)

    When "running the global cd resolve CLI"
    stdout, stderr, status = Open3.capture3(
      env,
      DEV_BIN, "cd", "--resolve", "widgets",
      chdir: cwd,
    )

    Then "it prints the path and succeeds"
    status.success? == true
    stdout.strip == expected.to_s
    stderr == ""

    Cleanup
    FileUtils.rm_rf(src)
    FileUtils.rm_rf(cwd)
  end

  test "shell hook cds into the resolved path" do
    Given "a sourced bash hook and a unique checkout"
    # Use bash rather than zsh: Ubuntu CI images do not ship zsh by default,
    # and bash is in the same supported shell set as the hook installer.
    src = Dir.mktmpdir("dev-cd-src-")
    home = Dir.mktmpdir("dev-cd-home-")
    expected = make_git_repo(src, "github.com/d3mlabs/widgets")
    Dev::Cd::ShellHook.new(env: { "SHELL" => "/bin/bash", "HOME" => home }).ensure!
    bash_profile = File.read(File.join(home, ".bash_profile"))

    script = <<~BASH
      #{bash_profile}
      dev cd widgets
      pwd
    BASH

    When "running bash with the hook and a PATH that finds bin/dev"
    stdout, _stderr, status = Open3.capture3(
      { "DEV_CD_ROOT" => src, "PATH" => "#{File.dirname(DEV_BIN)}:#{ENV.fetch("PATH")}" },
      "bash", "-c", script,
    )

    Then "pwd is the checkout"
    status.success? == true
    stdout.lines.last.to_s.strip == expected.to_s

    Cleanup
    FileUtils.rm_rf(src)
    FileUtils.rm_rf(home)
  end
end
