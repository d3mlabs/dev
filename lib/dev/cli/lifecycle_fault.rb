# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # Why this dev could not read the project's `targets:` — and so neither
    # the channels nor the release derived from it: the lifecycle
    # vocabulary's refusal, carried instead of raised.
    #
    # A dev.yml is written for the dev of its day and read by every dev
    # after it and, for a while, before it (ADR-0001: projects pin no dev).
    # The lifecycle half is the half that grows a grammar, and a key this
    # dev predates — `files:` on the archive packager, say — must not stop
    # `dev up`, the verb that installs the lock and, in dev's own checkout,
    # the one after which the checkout's dev takes over (bin/dev), nor any
    # project command. So the loader keeps the refusal here, the Runner
    # registers the verbs the declaration implies as refusing stand-ins
    # (Builtins::FaultedVerbCommand), and the refusal surfaces, naming the
    # key, when one of them is asked for — never before.
    class LifecycleFault < T::Struct
      extend T::Sig

      # The vocabulary's refusal as the parser raised it; its message names
      # the key or value this dev could not read.
      const :refusal, ArgumentError
      # The derived verbs the declaration implies, which the Runner
      # registers as refusing: `build` and `package` always — `targets:` is
      # declared — and `deploy` and `release` when `commands:` declares them.
      const :verbs, T::Array[String]

      # @return [String] the refusal's message
      sig { returns(String) }
      def message
        refusal.message
      end
    end
  end
end
