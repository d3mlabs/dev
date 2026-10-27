# typed: strict
# frozen_string_literal: true

require "dev/command"
require "dev/deps/lockfile"
require "dev/runner_status"

module Dev
  module Builtins
    # `dev runner status` — inspect-only: this machine's discovered runner
    # enrollments and their contract facts (see Dev::RunnerStatus). Needs no
    # project (the machine view), but reports the container contract when
    # run inside a project that declares a build container. A leaf of the
    # `runner` group (RunnerRegisterCommand and RunnerUnregisterCommand are
    # the others).
    class RunnerStatusCommand < BuiltinCommand
      extend T::Sig

      # Builds the status inspector; injected for tests.
      StatusFactory = T.type_alias do
        T.proc.params(container_required: T::Boolean, project_root: T.nilable(Pathname)).returns(Dev::RunnerStatus)
      end

      sig { params(runner_status_factory: StatusFactory).void }
      def initialize(runner_status_factory: ->(container_required, project_root) {
        # The lock is what the host identity's reach is checked over; none
        # outside a checkout.
        pins = project_root ? Dev::Deps::Lockfile.new(dir: project_root).read : []
        Dev::RunnerStatus.new(container_required:, pins:)
      })
        super()
        @runner_status_factory = runner_status_factory
      end

      sig { override.returns(String) }
      def desc = "Inspect this host's runner enrollments and their contract facts"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        _ = args
        @runner_status_factory.call(context.project&.project_images&.containerized? || false, context.project&.root).report
      end
    end
  end
end
