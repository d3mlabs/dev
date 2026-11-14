# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "gh"
require_relative "snapshot_branch"
require_relative "workflow_run"

module Dev
  module Lifecycle
    # The forge's side of a `workflow_dispatch`, over gh: dispatch a
    # workflow on a ref with inputs, find the run that dispatch made, watch
    # it to its end, bring an artifact of it back. The dispatch endpoint
    # returns no run id, so the run is found by its snapshot branch, which
    # exists for this dispatch alone. The listing lags the dispatch by
    # seconds, so `locate` polls, bounded.
    class WorkflowRuns
      extend T::Sig

      # The dispatch was accepted and no run of it was listed within the wait.
      class RunNotListedError < RuntimeError; end

      # The watch broke before the run ended (a lost connection, gh
      # killed); the run itself continues on the forge.
      class WatchLostError < RuntimeError; end

      # gh answered with something that is not a run.
      class MalformedRunError < RuntimeError; end

      # What `gh run list`/`gh run view --json` are asked for.
      FIELDS = "databaseId,url,status,conclusion"
      # The event the generic workflow runs on; narrows the listing to
      # dispatches should a project ever add another trigger to its copy.
      EVENT = "workflow_dispatch"
      # How long `locate` waits for the listing to show the run.
      LOCATE_ATTEMPTS = 30
      LOCATE_INTERVAL_SECONDS = 2

      Sleeper = T.type_alias { T.proc.params(seconds: Integer).void }

      # @param gh [Gh] over the project's checkout
      # @param sleeper [Proc] how `locate` waits between listings (injectable for tests)
      sig { params(gh: Gh, sleeper: Sleeper).void }
      def initialize(gh:, sleeper: ->(seconds) { Kernel.sleep(seconds) })
        @gh = gh
        @sleeper = sleeper
      end

      # Dispatch a workflow on a ref.
      #
      # @param workflow [String] the workflow's file name
      # @param ref [String] the branch the run checks out
      # @param inputs [Hash{String => String}]
      # @return [void]
      # @raise [Gh::CommandFailedError] the forge refused (no such workflow on the ref, no permission)
      sig { params(workflow: String, ref: String, inputs: T::Hash[String, String]).void }
      def dispatch(workflow:, ref:, inputs:)
        fields = inputs.flat_map { |name, value| ["-f", "#{name}=#{value}"] }
        @gh.capture(["workflow", "run", workflow, "--ref", ref, *fields])
      end

      # The run a dispatch on a snapshot branch made, once the forge lists it.
      #
      # @param workflow [String] the workflow's file name
      # @param branch [SnapshotBranch] the dispatch's ref
      # @return [WorkflowRun]
      # @raise [RunNotListedError]
      # @raise [Gh::CommandFailedError]
      # @raise [MalformedRunError]
      sig { params(workflow: String, branch: SnapshotBranch).returns(WorkflowRun) }
      def locate(workflow:, branch:)
        LOCATE_ATTEMPTS.times do |attempt|
          @sleeper.call(LOCATE_INTERVAL_SECONDS) if attempt.positive?
          listed = JSON.parse(@gh.capture(
            ["run", "list", "--workflow", workflow, "--branch", branch.name, "--event", EVENT, "--limit", "1", "--json", FIELDS],
          ))
          run = Array(listed).first
          return run_from(run) if run
        end
        raise RunNotListedError,
          "GitHub listed no run of #{workflow} on #{branch} within #{LOCATE_ATTEMPTS * LOCATE_INTERVAL_SECONDS}s of the dispatch — " \
            "look at the workflow's Actions page"
      rescue JSON::ParserError => e
        raise MalformedRunError, "gh run list answered with something that is not JSON: #{e.message}"
      end

      # Follow a run to its end on the operator's terminal, then read its
      # verdict.
      #
      # @param run [WorkflowRun]
      # @return [WorkflowRun] the run as completed
      # @raise [WatchLostError]
      # @raise [Gh::CommandFailedError] the verdict could not be read
      # @raise [MalformedRunError]
      sig { params(run: WorkflowRun).returns(WorkflowRun) }
      def watch(run)
        begin
          @gh.stream(["run", "watch", run.id.to_s])
        rescue Gh::CommandFailedError => e
          raise WatchLostError, "lost the watch on #{run.url} (#{e.message}); the run continues on GitHub"
        end
        view(run)
      end

      # The run as the forge holds it now.
      #
      # @param run [WorkflowRun]
      # @return [WorkflowRun]
      # @raise [Gh::CommandFailedError]
      # @raise [MalformedRunError]
      sig { params(run: WorkflowRun).returns(WorkflowRun) }
      def view(run)
        run_from(JSON.parse(@gh.capture(["run", "view", run.id.to_s, "--json", FIELDS])))
      rescue JSON::ParserError => e
        raise MalformedRunError, "gh run view answered with something that is not JSON: #{e.message}"
      end

      # Download one artifact of a run into a directory.
      #
      # @param run [WorkflowRun]
      # @param name [String] the workflow artifact's name
      # @param into [Pathname] created when absent
      # @return [void]
      # @raise [Gh::CommandFailedError] no artifact of that name, or the run has none
      sig { params(run: WorkflowRun, name: String, into: Pathname).void }
      def download(run, name:, into:)
        into.mkpath
        @gh.capture(["run", "download", run.id.to_s, "--name", name, "--dir", into.to_s])
      end

      private

      # @param record [Object] one object of gh's `--json` answer
      # @return [WorkflowRun]
      # @raise [MalformedRunError]
      sig { params(record: T.untyped).returns(WorkflowRun) }
      def run_from(record)
        raise MalformedRunError, "gh answered with #{record.inspect}, not a run" unless record.is_a?(Hash)

        WorkflowRun.new(
          id: Integer(record.fetch("databaseId")),
          url: record.fetch("url").to_s,
          status: record.fetch("status").to_s,
          conclusion: record["conclusion"].to_s.empty? ? nil : record["conclusion"].to_s,
        )
      rescue KeyError, ArgumentError, TypeError => e
        raise MalformedRunError, "gh answered with a run dev cannot read (#{e.message}): #{record.inspect}"
      end
    end
  end
end
