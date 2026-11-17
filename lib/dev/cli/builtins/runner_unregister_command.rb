# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/cli/command"
require "dev/runner_discovery"
require "dev/runner_teardown"

module Dev
  module Cli
    module Builtins
      # `dev runner unregister [<scope>|<dir>] [--yes]` — the exit of the
      # enrollment lifecycle register enters and status inspects: remove
      # one of this host's runner enrollments (service, GitHub registration,
      # enrollment files; binaries stay — see Dev::RunnerTeardown).
      #
      #   dev runner unregister d3mlabs               # by scope: the enrollment — or every slot this host has there
      #   dev runner unregister ~/actions-runner-2    # by dir — always one slot
      #   dev runner unregister                       # lists this host's enrollments by scope and asks which
      #
      # The scope is the last part of a family's frame title in `dev runner
      # status` (`agent · 3 slots · d3mlabs`); a dir's name is history and
      # says nothing reliable about its scope, so the bare form lists every
      # enrollment under its scope before asking. Destructive, so it asks —
      # naming scope, runner, dir and whether a service is installed, once
      # for several slots — unless `--yes`, which needs the enrollment named:
      # a bare yes has nothing to be sure of. Enrollments are resolved by
      # discovery alone (every `~/actions-runner*/.runner`; never gh), so a
      # scope several dirs serve that are not one set of slots is refused
      # with the dirs to name instead. A leaf of the `runner` group.
      class RunnerUnregisterCommand < BuiltinCommand
        extend T::Sig

        # The bare form was run where nothing is enrolled: there is nothing
        # to list, nothing to ask. A RuntimeError so the CLI boundary prints
        # it and exits 1.
        class NothingEnrolledError < RuntimeError; end

        # The bare form could not be asked which enrollment — `--yes` with
        # no argument, or no terminal to pick at — so nothing changed: the
        # message names the scopes to pick from.
        class UnnamedEnrollmentError < RuntimeError; end

        YES_FLAG = "--yes"

        # @param teardown [Dev::RunnerTeardown] resolves and removes enrollments
        # @param discovery [Dev::RunnerDiscovery] this host's enrollments
        # @param out [IO, StringIO]
        sig { params(teardown: Dev::RunnerTeardown, discovery: Dev::RunnerDiscovery, out: T.any(IO, StringIO)).void }
        def initialize(teardown: Dev::RunnerTeardown.new, discovery: Dev::RunnerDiscovery.new, out: $stdout)
          super()
          @teardown = teardown
          @discovery = discovery
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "Remove one of this host's runner enrollments, or every slot it has at a scope"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Environment
        end

        # The enrollment is named one of two ways, or picked from the list
        # the bare form shows.
        sig { override.returns(T.nilable(String)) }
        def synopsis
          "[<scope>|<dir>]"
        end

        sig { override.returns(T::Array[Cli::Positional]) }
        def positionals
          [
            Cli::Positional.new(
              "scope", optional: true,
              desc: "an owner or owner/repo, as a family's frame in `dev runner status` ends: every slot this host has there",
            ),
            Cli::Positional.new("dir", optional: true, desc: "a runner directory, e.g. ~/actions-runner-2: that one slot"),
          ]
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [Cli::Flag.new(YES_FLAG, desc: "skip the confirmation; needs the enrollment named")]
        end

        # What the enrollment argument can be, from discovery alone (offline;
        # never gh): every local scope once, in discovery order, then every
        # `~`-dir — so typing an owner narrows to scopes and `~` to dirs.
        # Nothing once an enrollment is named; flags never count as one. The
        # order is deliberate and the plumbing keeps it.
        sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
        def completions(words)
          return [] if words.any? { |word| !word.start_with?("--") }

          references(@discovery.enrollments)
        end

        # Resolve the reference — the argument, or the bare form's pick —
        # ask once through the context's Ui (no terminal is a no; `--yes`
        # answers for it), tear down every slot resolved — slot order, so a
        # refusal partway leaves the lower slots gone and the rest named by
        # the error.
        #
        # @raise [NothingEnrolledError] the bare form on a host with no enrollments
        # @raise [UnnamedEnrollmentError] the bare form with `--yes`, or with no terminal to pick at
        # @raise [Dev::RunnerTeardown::AmbiguousEnrollmentError] a scope several dirs serve that are not one set of slots
        # @raise [Dev::RunnerTeardown::NoSuchEnrollmentError] nothing matches
        # @raise [Dev::RunnerTeardown::TeardownFailedError] a step was refused
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          reference = args.positionals.first || pick(yes: args.flag?(YES_FLAG), ui: context.ui)
          enrollments = @teardown.resolve_all(reference)
          unless args.flag?(YES_FLAG) || context.ui.confirm(question(enrollments))
            @out.puts "dev: nothing changed."
            return
          end

          enrollments.each { |enrollment| @teardown.teardown!(enrollment, ui: context.ui) }
        end

        private

        # The bare form: every enrollment on this host listed under its
        # scope, then one picked from the same candidates Tab completes
        # (every scope, then every dir). `--yes` is refused first — before
        # anything is listed or asked — since a yes to a question never
        # put names nothing.
        #
        # @param yes [Boolean] `--yes`
        # @param ui [Ui] asks; no terminal is a refusal
        # @return [String] a scope or a dir
        # @raise [NothingEnrolledError] when the host has no enrollments
        # @raise [UnnamedEnrollmentError] with `--yes`, or when nobody can pick
        sig { params(yes: T::Boolean, ui: Ui).returns(String) }
        def pick(yes:, ui:)
          enrollments = @discovery.enrollments
          raise NothingEnrolledError, "no runner is enrolled on this host — nothing to unregister" if enrollments.empty?

          by_scope = enrollments.group_by(&:scope)
          raise UnnamedEnrollmentError, unnamed("#{YES_FLAG} with no enrollment named", by_scope) if yes

          @out.puts "This host's enrollments:"
          by_scope.each do |scope, slots|
            @out.puts "  #{scope} — #{plural(slots.length, "slot")}"
            slots.each { |enrollment| @out.puts "    #{enrollment.name} (#{describe(enrollment)})" }
          end
          picked = ui.choose("Unregister which scope or dir?", references(enrollments))
          picked || raise(UnnamedEnrollmentError, unnamed("no terminal to ask at", by_scope))
        end

        # The refusal's message: why, the two forms of the argument, and
        # the scopes this host serves so the next run can name one.
        #
        # @param why [String]
        # @param by_scope [Hash{String => Array<Dev::RunnerDiscovery::Enrollment>}]
        # @return [String]
        sig { params(why: String, by_scope: T::Hash[String, T::Array[Dev::RunnerDiscovery::Enrollment]]).returns(String) }
        def unnamed(why, by_scope)
          serves = by_scope.map { |scope, slots| "#{scope}: #{plural(slots.length, "slot")}" }.join(", ")
          "nothing changed: #{why} — name the enrollment: `dev runner unregister <scope>` or `<dir>` (this host serves #{serves})"
        end

        # Every way the enrollments can be named: each scope once, in
        # discovery order, then each dir — the completion list and the bare
        # form's options alike.
        #
        # @param enrollments [Array<Dev::RunnerDiscovery::Enrollment>]
        # @return [Array<String>]
        sig { params(enrollments: T::Array[Dev::RunnerDiscovery::Enrollment]).returns(T::Array[String]) }
        def references(enrollments)
          enrollments.map(&:scope).uniq + enrollments.map(&:display_dir)
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

        # @param count [Integer]
        # @param noun [String]
        # @return [String] "1 slot", "3 slots"
        sig { params(count: Integer, noun: String).returns(String) }
        def plural(count, noun)
          "#{count} #{noun}#{"s" unless count == 1}"
        end
      end
    end
  end
end
