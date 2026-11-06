# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"
require "dev/dispatch"
require "dev/lifecycle"
require "dev/transport"
require "fileutils"
require "pathname"
require "stringio"
require "support/fake_gh"
require "tmpdir"

# The sealed dispatch: Native yields for the env and hands it back as
# Run(env); Remote carries the verb over a real snapshot branch (a temp
# bare origin) through a transport whose forge is scripted (FakeGh), and
# never asks for the env — the seam runs on the host.
transform!(RSpock::AST::Transformation)
class Dev::DispatchTest < Minitest::Test
  include SorbetHelper

  RUN = { "databaseId" => 42, "url" => "https://github.com/o/r/actions/runs/42", "status" => "queued", "conclusion" => nil }.freeze
  GREEN = RUN.merge("status" => "completed", "conclusion" => "success").freeze

  test "the native dispatch resolves the env and hands it back as Run(env): the seam runs here, unchanged" do
    Given "a native dispatch and a verb's env"
    env = { build: "cellbound-3d-win64-dev", install: "/var/lib/dev/artifacts/x" }
    invocation = Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])

    When
    outcome = Dev::Dispatch::Native.new.dispatch(invocation) { env }

    Then "the outcome is Run over the very env"
    outcome.is_a?(Dev::Dispatch::Outcome::Run)
    outcome.env.equal?(env)
    outcome == Dev::Dispatch::Outcome::Run.new(env)
  end

  test "the remote dispatch pushes the snapshot, prints the crossing, runs the verb there over the branch, and is Done without ever resolving the env" do
    Given "a checkout with an origin, the project's copy of the workflow, and a forge that lists and finishes the run"
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: GREEN)
    out = StringIO.new
    ui = Dev::Cli::NoUi.new
    remote = Dev::Dispatch::Remote.new(transport: transport(gh, root:, out:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui:)
    resolved = false
    heads_at_dispatch = nil
    heads = -> { remote_heads(origin) }
    gh.define_singleton_method(:stream) do |argv|
      heads_at_dispatch = heads.call
      capture(argv)
    end

    When
    outcome = capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])) { resolved = true } }

    Then "Done, the env never asked for; the workflow was dispatched on the snapshot branch with the verb, the label and no fetch, then located by that branch, watched, and read back"
    outcome == Dev::Dispatch::Outcome::Done.new
    !resolved
    dispatched = gh.calls.find { |call| call.argv.first(2) == ["workflow", "run"] }.argv
    branch = dispatched.fetch(4)
    branch.start_with?("dev/build/ue-engine-hosted/")
    dispatched == ["workflow", "run", "dev-lifecycle.yml", "--ref", branch, "-f", "verbs=build cellbound-3d-win64-dev", "-f", "runner=ue-engine-hosted", "-f", "fetch=false"]
    gh.calls.map { |call| call.argv.first(2) } == [["workflow", "run"], ["run", "list"], ["run", "watch"], ["run", "view"]]
    gh.calls.fetch(1).argv.include?(branch)
    gh.calls.fetch(2).argv == ["run", "watch", "42"]
    heads_at_dispatch.keys.include?("refs/heads/#{branch}")
    remote_heads(origin).keys == ["refs/heads/main"]
    out.string == "dispatched `dev build cellbound-3d-win64-dev` on ue-engine-hosted: https://github.com/o/r/actions/runs/42\n"

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the crossing line names the runner and the snapshot's short sha" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: GREEN)
    ui = typed_mock(Dev::Cli::Ui)
    remote = Dev::Dispatch::Remote.new(transport: transport(gh, root:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui:)
    crossing = nil
    ui.expects(:print_remote_crossing).with { |runner:, snapshot:| crossing = [runner, snapshot] }

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { flunk("the env was resolved") }

    Then
    crossing.fetch(0) == "ue-engine-hosted"
    crossing.fetch(1).match?(/\A\h{12}\z/)

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a project without the workflow is refused before anything is pushed, with the copy named" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    gh = FakeGh.new(root:)
    remote = Dev::Dispatch::Remote.new(transport: transport(gh, root:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: typed_mock(Dev::Cli::Ui))

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil }

    Then
    error = raises(Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError)
    error.message.include?("#{root} has no .github/workflows/dev-lifecycle.yml")
    error.message.include?("cp #{Dev::Lifecycle::LifecycleWorkflow::SOURCE} .github/workflows/dev-lifecycle.yml")
    gh.calls.empty?
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a run that ends red is RemoteVerbFailedError naming the verb, the label, the verdict and the page; the branch is still deleted" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: RUN.merge("status" => "completed", "conclusion" => "failure"))
    remote = Dev::Dispatch::Remote.new(transport: transport(gh, root:, out: StringIO.new), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: Dev::Cli::NoUi.new)

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x"])) { nil } }

    Then
    error = raises(Dev::Transport::ActionsRunner::RemoteVerbFailedError)
    error.message == "`dev package x` on ue-engine-hosted ended with failure: https://github.com/o/r/actions/runs/42"
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "Run outcomes compare by their env; Done outcomes are all equal; the two never equal each other" do
    Given
    run = Dev::Dispatch::Outcome::Run.new("a")
    same = Dev::Dispatch::Outcome::Run.new("a")
    other = Dev::Dispatch::Outcome::Run.new("b")
    done = Dev::Dispatch::Outcome::Done.new

    Expect
    run == same
    run.eql?(same)
    run.hash == same.hash
    run != other
    run != done
    done == Dev::Dispatch::Outcome::Done.new
    done.hash == Dev::Dispatch::Outcome::Done.new.hash
    done != run
    done != "done"
  end

  test "native dispatches are all equal, and no other value" do
    Expect
    Dev::Dispatch::Native.new == Dev::Dispatch::Native.new
    Dev::Dispatch::Native.new.hash == Dev::Dispatch::Native.new.hash
    Dev::Dispatch::Native.new != Dev::Dispatch::Outcome::Done.new
  end

  test "the dispatch, its outcome and the transport are sealed: a variant declared elsewhere is refused" do
    When "including the sealed module outside its declaring file"
    Class.new { include sealed }

    Then
    raises RuntimeError

    Where
    sealed
    Dev::Dispatch
    Dev::Dispatch::Outcome
    Dev::Transport
  end

  test "#{variant} is final: subclassing raises" do
    When
    Class.new(variant)

    Then
    raises RuntimeError

    Where
    variant
    Dev::Dispatch::Native
    Dev::Dispatch::Remote
    Dev::Dispatch::Outcome::Run
    Dev::Dispatch::Outcome::Done
    Dev::Transport::ActionsRunner
  end

  private

  def transport(gh, root:, out: StringIO.new)
    Dev::Transport::ActionsRunner.new(
      runner: "ue-engine-hosted",
      runs: Dev::Lifecycle::WorkflowRuns.new(gh:, sleeper: ->(_seconds) { nil }),
      workflow: Dev::Lifecycle::LifecycleWorkflow.new(root:),
      out:,
    )
  end

  def install_workflow(root)
    Dev::Lifecycle::LifecycleWorkflow.new(root:).path.tap { |path| path.dirname.mkpath }.write(Dev::Lifecycle::LifecycleWorkflow::SOURCE.read)
  end

  def checkout_with_origin(workspace)
    origin = workspace / "origin.git"
    root = workspace / "checkout"
    Dev::Lifecycle::Git.new(root: workspace).capture(["init", "-q", "--bare", origin.to_s])
    root.mkpath
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q", "-b", "main"])
    (root / "a.txt").write("a\n")
    git.capture(["add", "a.txt"])
    git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
    git.capture(["remote", "add", "origin", origin.to_s])
    git.capture(["push", "-q", "-u", "origin", "main"])
    [root, origin]
  end

  def remote_heads(origin)
    Dev::Lifecycle::Git.new(root: origin).capture(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/"])
      .lines.to_h { |line| line.strip.split(" ", 2) }
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = previous
  end
end
