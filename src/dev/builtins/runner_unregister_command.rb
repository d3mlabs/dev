# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/command"
require "dev/confirmer"
require "dev/runner_discovery"
require "dev/runner_setup"
require "dev/runner_teardown"

module Dev
  module Builtins
    # `dev runner unregister [<enrollment>] [--yes] [--org]` — the exit of
    # the enrollment lifecycle register enters and status inspects: remove
    # one of this host's runner enrollments (service, GitHub registration,
    # enrollment files; binaries stay — see Dev::RunnerTeardown).
    #
    #   dev runner unregister JPDuchesne/snappy     # by scope, when one enrollment serves it
    #   dev runner unregister ~/actions-runner      # by dir — always unambiguous
    #   dev runner unregister                       # the checkout's scope, like register
    #   dev runner unregister --org                 # the checkout's owner
    #
    # Destructive, so it asks — naming scope, runner, dir and whether a
    # service is installed — unless `--yes`. The enrollment is resolved by
    # discovery alone (every `~/actions-runner*/.runner`), so a scope
    # several dirs serve is refused with the dirs to name instead. A leaf
    # of the `runner` group.
    class RunnerUnregisterCommand < BuiltinCommand
      extend T::Sig

      YES_FLAG = "--yes"
      ORG_FLAG = "--org"

      # Answers "owner/repo" for the enclosing checkout; the gh boundary
      # behind the no-argument form.
      RepoResolver = T.type_alias { T.proc.returns(String) }

      # @param teardown [Dev::RunnerTeardown] resolves and removes enrollments
      # @param discovery [Dev::RunnerDiscovery] this host's enrollments
      # @param repo_resolver [RepoResolver] the checkout's repo (default: gh)
      # @param confirmer [Dev::Confirmer] asks before removing
      # @param out [IO, StringIO]
      sig do
        params(
          teardown: Dev::RunnerTeardown,
          discovery: Dev::RunnerDiscovery,
          repo_resolver: RepoResolver,
          confirmer: Dev::Confirmer,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(
        teardown: Dev::RunnerTeardown.new,
        discovery: Dev::RunnerDiscovery.new,
        repo_resolver: -> { Dev::RunnerSetup.current_repo },
        confirmer: Dev::Confirmer.new,
        out: $stdout
      )
        super()
        @teardown = teardown
        @discovery = discovery
        @repo_resolver = repo_resolver
        @confirmer = confirmer
        @out = out
      end

      sig { override.returns(String) }
      def desc = "Remove one of this host's runner enrollments, named by scope or dir (--yes skips the confirmation)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Lifecycle

      # Resolve, ask, tear down.
      #
      # @raise [Dev::RunnerTeardown::AmbiguousEnrollmentError] a scope several dirs serve
      # @raise [Dev::RunnerTeardown::NoSuchEnrollmentError] nothing matches
      # @raise [Dev::RunnerTeardown::TeardownFailedError] a step was refused
      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        _ = context
        enrollment = @teardown.resolve(reference(args))
        unless args.include?(YES_FLAG) || @confirmer.confirm?(question(enrollment))
          @out.puts "dev: nothing changed."
          return
        end

        @teardown.teardown!(enrollment)
      end

      private

      # The positional reference, else the checkout's scope (its owner
      # with --org) — the same default register enrolls.
      #
      # @param args [Array<String>]
      # @return [String] a scope or a dir
      sig { params(args: T::Array[String]).returns(String) }
      def reference(args)
        positional = args.find { |arg| !arg.start_with?("--") }
        return positional if positional

        repo = @repo_resolver.call
        args.include?(ORG_FLAG) ? repo.split("/").fetch(0) : repo
      end

      # @param enrollment [Dev::RunnerDiscovery::Enrollment]
      # @return [String] the question, without the [y/N] cue
      sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).returns(String) }
      def question(enrollment)
        service = enrollment.service_installed ? "service installed" : "no service"
        "Unregister #{enrollment.name} from #{enrollment.scope} (#{enrollment.display_dir}, #{service})?"
      end
    end
  end
end
