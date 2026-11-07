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
    #   dev runner unregister d3mlabs               # by scope: the enrollment — or every slot this host has there
    #   dev runner unregister ~/actions-runner-2    # by dir — always one slot
    #   dev runner unregister                       # the checkout's scope, like register
    #   dev runner unregister --org                 # the checkout's owner
    #
    # Destructive, so it asks — naming scope, runner, dir and whether a
    # service is installed, once for several slots (dev#470) —
    # unless `--yes`. Enrollments are resolved by discovery alone (every
    # `~/actions-runner*/.runner`), so a scope several dirs serve that are
    # not one set of slots is refused with the dirs to name instead. A leaf of
    # the `runner` group.
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
      def desc = "Remove one of this host's runner enrollments — or every slot it has at a scope — named by scope or dir (--yes skips the confirmation)"

      sig { override.returns(Command::Category) }
      def category = Command::Category::Environment

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = [Cli::Flag.new(YES_FLAG), Cli::Flag.new(ORG_FLAG)]

      # What the enrollment argument can be, from discovery alone (offline;
      # never gh): every local scope once, in discovery order, then every
      # `~`-dir — so typing an owner narrows to scopes and `~` to dirs.
      # Nothing once an enrollment is named; flags never count as one. The
      # order is deliberate and the plumbing keeps it (#211).
      sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
      def completions(words)
        return [] if words.any? { |word| !word.start_with?("--") }

        enrollments = @discovery.enrollments
        enrollments.map(&:scope).uniq + enrollments.map(&:display_dir)
      end

      # Resolve, ask once, tear down every slot resolved — slot order, so a
      # refusal partway leaves the lower slots gone and the rest
      # named by the error.
      #
      # @raise [Dev::RunnerTeardown::AmbiguousEnrollmentError] a scope several dirs serve that are not one set of slots
      # @raise [Dev::RunnerTeardown::NoSuchEnrollmentError] nothing matches
      # @raise [Dev::RunnerTeardown::TeardownFailedError] a step was refused
      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
      def call(args:, context:)
        _ = context
        enrollments = @teardown.resolve_all(reference(args))
        unless args.flag?(YES_FLAG) || @confirmer.confirm?(question(enrollments))
          @out.puts "dev: nothing changed."
          return
        end

        enrollments.each { |enrollment| @teardown.teardown!(enrollment) }
      end

      private

      # The positional reference, else the checkout's scope (its owner
      # with --org) — the same default register enrolls.
      #
      # @param args [Array<String>]
      # @return [String] a scope or a dir
      sig { params(args: Cli::ParsedArgs).returns(String) }
      def reference(args)
        positional = args.positionals.first
        return positional if positional

        repo = @repo_resolver.call
        args.flag?(ORG_FLAG) ? repo.split("/").fetch(0) : repo
      end

      # One question for everything resolved: a lone enrollment named in
      # full; several slots listed one by one, then asked about as a whole.
      #
      # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>] slot order, never empty
      # @return [String] the question, without the [y/N] cue
      sig { params(enrollments: T::Array[Dev::RunnerDiscovery::Enrollment]).returns(String) }
      def question(enrollments)
        first = T.must(enrollments.first)
        return "Unregister #{first.name} from #{first.scope} (#{describe(first)})?" if enrollments.length == 1

        @out.puts "#{enrollments.length} slots on this host serve #{first.scope}:"
        enrollments.each { |enrollment| @out.puts "  #{enrollment.name} (#{describe(enrollment)})" }
        "Unregister all #{enrollments.length}?"
      end

      # @param enrollment [Dev::RunnerDiscovery::Enrollment]
      # @return [String] its dir and whether a service is installed
      sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).returns(String) }
      def describe(enrollment)
        "#{enrollment.display_dir}, #{enrollment.service_installed ? "service installed" : "no service"}"
      end
    end
  end
end
