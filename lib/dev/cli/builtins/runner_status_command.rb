# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/deps/lockfile"
require "dev/runner_setup"
require "dev/runner_status"
require "dev/ui"

module Dev
  module Cli
    module Builtins
      # `dev runner status` — inspect-only: this machine's discovered runner
      # enrollments and their contract facts (see Dev::RunnerStatus). Needs no
      # project (the machine view), but reports the container contract when
      # run inside a project that declares a build container. `--check` is
      # the host's posture alone, GitHub not asked, exiting 1 on any red
      # fact — what a job runs after `dev up`. A leaf of the `runner` group
      # (RunnerRegisterCommand and RunnerUnregisterCommand are the others).
      class RunnerStatusCommand < BuiltinCommand
        extend T::Sig

        CHECK_FLAG = "--check"

        # Builds the status inspector over the context's Ui; injected for tests.
        StatusFactory = T.type_alias do
          T.proc.params(container_required: T::Boolean, project_root: T.nilable(Pathname), ui: Dev::Ui).returns(Dev::RunnerStatus)
        end

        sig { params(runner_status_factory: StatusFactory).void }
        def initialize(runner_status_factory: ->(container_required, project_root, ui) {
          # The lock is what the host identity's reach is checked over, and the
          # checkout's repo is whose access to each org scope's slots is reported;
          # neither outside a checkout (an unresolvable checkout is no repo).
          pins = project_root ? Dev::Deps::Lockfile.new(dir: project_root).read : []
          repo = project_root ? self.class.current_repo : nil
          Dev::RunnerStatus.new(container_required:, pins:, repo:, ui:)
        })
          super()
          @runner_status_factory = runner_status_factory
        end

        class << self
          extend T::Sig

          # The checkout's repo as GitHub spells it, or nil when gh cannot say
          # (status is inspect-only: an unresolvable checkout is not an error).
          #
          # @return [String, nil]
          sig { returns(T.nilable(String)) }
          def current_repo
            Dev::RunnerSetup.current_repo
          rescue Dev::RunnerSetup::Error
            nil
          end
        end

        # The summary line, then what `--check` is for.
        sig { override.returns(String) }
        def desc
          <<~DESC
            Inspect this host's runner enrollments and their contract facts (--check: the host's posture, exit 1 on drift)

            The machine's view, framed by subject: the host, then one frame per role
            family — each slot's reach, online state and labels against what its role
            expects — then the posture line. Nothing is recorded; every fact is
            re-derived from the host and GitHub each time, and the remedy is named
            on each red line (most: re-run `dev runner register`).

            #{CHECK_FLAG} inspects the host's posture alone — the runner user and its login,
            the toolchain, the agent host (its user, group memberships, sudoers edge,
            data root, brew locks), the WSL runner host, host tooling — and exits 1
            when any fact is red. GitHub is not asked: the family facts need the org
            token and are the human's run. Which roles are enrolled is read from each
            enrollment's own record, so it runs in every job on the job's identity;
            a host whose posture is behind the running dev's contract goes red in the
            job's log. Posture stays register's to converge: a job inspects it.
          DESC
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [
            Cli::Flag.new(CHECK_FLAG, desc: "the host's posture alone, GitHub not asked: the host frame and the posture line, exit 1 when any fact is red — for every job, on its own identity"),
          ]
        end

        # The full report, or with `--check` the host's posture alone
        # (Dev::RunnerStatus#check raises on drift; the boundary exits 1).
        #
        # @raise [Dev::RunnerStatus::PostureDriftError] `--check`, with a red fact
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          status = @runner_status_factory.call(context.project&.project_images&.containerized? || false, context.project&.root, context.ui)
          args.flag?(CHECK_FLAG) ? status.check : status.report
        end
      end
    end
  end
end
