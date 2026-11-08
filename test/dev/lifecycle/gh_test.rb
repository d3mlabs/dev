# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle/gh"
require "fileutils"
require "pathname"
require "tmpdir"

# Gh is the one place the lifecycle spawns gh, so this is the one test that
# spawns anything: a stub `gh` executable on PATH that records what it was
# asked and answers as scripted. The forge is never reached.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::GhTest < Minitest::Test
  def setup
    @dir = Pathname(Dir.mktmpdir("dev-gh-test-"))
    @root = @dir / "checkout"
    @bin = @dir / "bin"
    FileUtils.mkdir_p(@root)
    FileUtils.mkdir_p(@bin)
    @old_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{@bin}:#{@old_path}"
  end

  def teardown
    ENV["PATH"] = @old_path
    FileUtils.rm_rf(@dir)
    super
  end

  # A gh that writes its argv, stdin and cwd to files, prints `out`, writes
  # `err` to stderr and exits `status`.
  def stub_gh(out: "", err: "", status: 0)
    (@bin / "gh").write(<<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "#{@dir}/argv"
      cat > "#{@dir}/stdin"
      pwd > "#{@dir}/cwd"
      printf '%s' '#{err}' >&2
      printf '%s' '#{out}'
      exit #{status}
    SH
    (@bin / "gh").chmod(0o755)
  end

  test "capture runs gh in the checkout with the argv and body given, and returns what it printed" do
    Given
    stub_gh(out: "d3mlabs/cellbound-3d\n")

    When
    out = Dev::Lifecycle::Gh.new(root: @root).capture(["api", "-X", "POST", "--input", "-", "repos/o/r/deployments"], stdin: "{\"ref\":\"abc\"}")

    Then "stdout as printed; the argv, the body and the cwd are what gh saw"
    out == "d3mlabs/cellbound-3d\n"
    (@dir / "argv").read.lines(chomp: true) == ["api", "-X", "POST", "--input", "-", "repos/o/r/deployments"]
    (@dir / "stdin").read == "{\"ref\":\"abc\"}"
    Pathname((@dir / "cwd").read.strip).realpath == @root.realpath
  end

  test "a nonzero gh is CommandFailedError naming the argv, the checkout and gh's stderr" do
    Given
    stub_gh(err: "HTTP 403: Resource not accessible by integration", status: 1)

    When
    Dev::Lifecycle::Gh.new(root: @root).capture(["api", "repos/o/r/deployments"])

    Then
    error = raises(Dev::Lifecycle::Gh::CommandFailedError)
    error.message == "gh api repos/o/r/deployments failed in #{@root}: HTTP 403: Resource not accessible by integration"
  end

  test "no gh on PATH is GhMissingError" do
    Given "a PATH holding only the empty stub dir"
    ENV["PATH"] = @bin.to_s

    When
    Dev::Lifecycle::Gh.new(root: @root).capture(["repo", "view"])

    Then
    error = raises(Dev::Lifecycle::Gh::GhMissingError)
    error.message == "gh not found on PATH"
  end

  test "stream runs gh in the checkout on this process's stdout and stderr, with nothing on its stdin: the argv and cwd are gh's, nothing is captured" do
    Given
    stub_gh(out: "✓ run 42 completed with 'success'\n")

    When
    Dev::Lifecycle::Gh.new(root: @root).stream(["run", "watch", "42"])

    Then "the stub's `cat` of stdin read nothing and returned, rather than waiting on dev's own"
    (@dir / "argv").read.lines(chomp: true) == ["run", "watch", "42"]
    (@dir / "stdin").read == ""
    Pathname((@dir / "cwd").read.strip).realpath == @root.realpath
  end

  test "a nonzero streamed gh is CommandFailedError naming the argv, the checkout and the exit" do
    Given
    stub_gh(status: 4)

    When
    Dev::Lifecycle::Gh.new(root: @root).stream(["run", "watch", "42"])

    Then
    error = raises(Dev::Lifecycle::Gh::CommandFailedError)
    error.message == "gh run watch 42 failed in #{@root} (exited 4)"
  end

  test "a streamed gh has the terminal, so under a spinner it is refused by the terminal's owner before it spawns (plans#52)" do
    Given
    stub_gh

    When
    error = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      Dev::TerminalOwner.spinning { Dev::Lifecycle::Gh.new(root: @root).stream(["run", "watch", "42"]) }
    end

    Then
    error.message.start_with?("`gh run watch 42` would take the terminal under a spinner")
    !(@dir / "argv").exist?
  end

  test "no gh on PATH is GhMissingError for a stream too" do
    Given
    ENV["PATH"] = @bin.to_s

    When
    Dev::Lifecycle::Gh.new(root: @root).stream(["run", "watch", "42"])

    Then
    raises Dev::Lifecycle::Gh::GhMissingError
  end
end
