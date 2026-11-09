# typed: false
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/ui"
require "dev/lifecycle"
require "dev/remote_dispatches"
require "support/fake_gh"

# The remote side of a lifecycle verb under test, with its two true
# boundaries scripted: the forge (FakeGh — a dispatch, a listed run, a
# watched run, a green verdict, and the download when asked) and the
# snapshot push (a SnapshotSync that yields one canned snapshot and
# touches no git). The real Dispatch::Remote, Transport::ActionsRunner,
# WorkflowRuns and LifecycleWorkflow run between them, so a verb test
# asserts what crossed — the invocation words the host would run — off
# the argv the forge saw. The project root must carry the workflow
# (install_workflow) or the dispatch refuses, as it would.
class ScriptedRemote
  RUN = { "databaseId" => 42, "url" => "https://github.com/o/r/actions/runs/42", "status" => "queued", "conclusion" => nil }.freeze
  GREEN = RUN.merge("status" => "completed", "conclusion" => "success").freeze
  SHA = "0123456789abcdef0123456789abcdef01234567"

  # Yields one snapshot of the given sha; records the labels synced for.
  class CannedSync < Dev::Lifecycle::SnapshotSync
    attr_reader :synced

    def initialize
      super(root: Pathname("/nonexistent"))
      @synced = []
    end

    def sync(runner:)
      @synced << runner
      yield Dev::Lifecycle::Snapshot.new(sha: SHA, branch: Dev::Lifecycle::SnapshotBranch.mint(runner:))
    end
  end

  attr_reader :gh, :sync, :out

  # @param root [Pathname] the project root the workflow is looked up under
  # @param ui [Dev::Ui] where the crossing line prints
  # @param downloads [Boolean] whether the forge also answers `run download`
  def initialize(root:, ui:, downloads: false)
    @root = root
    @gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: GREEN)
    @gh.answers(["run", "download"], with: "") if downloads
    @sync = CannedSync.new
    @out = StringIO.new
    @ui = ui
  end

  # @return [Dev::RemoteDispatches] what the resolver builds dispatches from
  def remotes
    Dev::RemoteDispatches.new(
      root: @root, ui: @ui, out: @out, sync: @sync,
      runs: Dev::Lifecycle::WorkflowRuns.new(gh: @gh, sleeper: ->(_seconds) { nil }),
    )
  end

  # Copy dev's workflow into the project, as an adopting repo commits it.
  def install_workflow
    Dev::Lifecycle::LifecycleWorkflow.new(root: @root).path.tap { |path| path.dirname.mkpath }.write(Dev::Lifecycle::LifecycleWorkflow::SOURCE.read)
  end

  # The inputs of the one dispatch the forge saw, by name; nil when none crossed.
  def dispatched_inputs
    call = @gh.calls.find { |recorded| recorded.argv.first(2) == ["workflow", "run"] }
    return nil if call.nil?

    call.argv.each_cons(2).select { |flag, _value| flag == "-f" }.to_h { |_flag, pair| pair.split("=", 2) }
  end

  # The `dev …` words the host would run; nil when nothing crossed.
  def dispatched_verbs = dispatched_inputs&.fetch("verbs")

  # The argv of the download, when one happened.
  def download
    @gh.calls.find { |recorded| recorded.argv.first(2) == ["run", "download"] }&.argv
  end
end
