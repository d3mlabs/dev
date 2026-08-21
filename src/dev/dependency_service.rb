# typed: strict
# frozen_string_literal: true

require "dev/deps"
require "dev/deps/baseline"
require "dev/deps/staleness"

module Dev
  # Narrow front over Dev::Deps::Staleness for the command use case: the
  # guard policy before a command runs, the current staleness messages, and
  # the installed-stamp write (lock!) after a stamping command succeeds.
  # Deliberately narrow — Lockfile and Deps::Cache consumers stay direct for
  # now; this fronts only Staleness (plus the host baseline's warn-only nag).
  class DependencyService
    extend T::Sig

    # Raised by the guard in CI, where a stale dependency state is a
    # pipeline bug, not a reminder.
    class StaleDependencyStateError < RuntimeError; end

    sig { params(staleness: Dev::Deps::Staleness, baseline: Dev::Deps::Baseline).void }
    def initialize(staleness:, baseline: Dev::Deps::Baseline.new)
      @staleness = T.let(staleness, Dev::Deps::Staleness)
      @baseline = T.let(baseline, Dev::Deps::Baseline)
    end

    # All current staleness messages (see Dev::Deps::Staleness#messages).
    #
    # @return [Array<String>] empty when everything is in sync
    sig { returns(T::Array[String]) }
    def messages
      @staleness.messages
    end

    # Two O(1) digest checks at every command start: manifest vs lockfile,
    # lockfile vs installed stamp. Warn on workstations; error in CI. The
    # host baseline gets its own check with softer semantics: always a
    # warning, even in CI — a drifted host tool set is never a reason to
    # block a project command (plans#26).
    #
    # @return [void]
    # @raise [StaleDependencyStateError] in CI, when any project layer is stale
    sig { void }
    def guard!
      baseline_message = @baseline.message
      $stderr.puts "dev: warning: #{baseline_message}" if baseline_message

      stale_messages = messages
      return if stale_messages.empty?

      if Dev::Deps.detect_env == "ci"
        raise StaleDependencyStateError,
          "stale dependency state:\n#{stale_messages.map { |m| "  #{m}" }.join("\n")}"
      end

      stale_messages.each { |m| $stderr.puts "dev: warning: #{m}" }
    end

    # Record the installed stamp after a fully-successful provisioning
    # command. Callers reach this only when execution didn't raise, so a
    # failed install keeps nagging.
    #
    # @return [void]
    sig { void }
    def lock!
      @staleness.stamp_installed!
    end
  end
end
