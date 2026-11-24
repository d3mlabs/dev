# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/cli/lifecycle_fault"
require "dev/version"

module Dev
  module Cli
    module Builtins
      # A lifecycle verb's stand-in where this dev could not read the
      # project's `targets:` (LifecycleFault): it lists where the verb
      # would, under Lifecycle, with the fault as its description, and
      # refuses when asked for — naming the key this dev does not know and
      # the way out. Never a LifecycleCommand: there is no seam to run, and
      # the verb's own flags and positionals are the readable declaration's
      # to spell. The Runner registers one per verb the declaration implies,
      # in place of the verb, so `dev up` and every project command run on a
      # dev.yml written for a newer dev (dev#689).
      class FaultedVerbCommand < BuiltinCommand
        extend T::Sig

        # The verb was asked for on a dev.yml whose `targets:` this dev
        # cannot read. RuntimeError so the CLI boundary reports it as a
        # clean `dev:` error; the message carries the vocabulary's refusal.
        class LifecycleFaultError < RuntimeError; end

        # @param verb [String] the derived verb this stands in for (build,
        #   package, deploy, release)
        # @param fault [LifecycleFault] why the declaration could not be read
        sig { params(verb: String, fault: LifecycleFault).void }
        def initialize(verb:, fault:)
          super()
          @verb = verb
          @fault = fault
        end

        sig { override.returns(String) }
        def desc
          "Refused: this dev cannot read dev.yml `targets:` — #{@fault.message}"
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Lifecycle
        end

        # The refusal is the whole body: a verb on a declaration this dev
        # cannot read has nothing to parse its argv against, so the words
        # are not checked — the refusal names the fault, not a flag.
        sig { override.returns(T::Boolean) }
        def opaque_args?
          true
        end

        # @param args [Cli::ParsedArgs] unread
        # @param context [ExecutionContext] unread
        # @return [void]
        # @raise [LifecycleFaultError] always, carrying the vocabulary's refusal verbatim
        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise LifecycleFaultError,
            "dev.yml `targets:` is not readable by this dev (#{Dev::Version.current}), so `dev #{@verb}` cannot run: " \
              "#{@fault.message} — the declaration was written for a newer dev: upgrade (`dev up` upgrades dev), " \
              "or fix the declaration"
        end
      end
    end
  end
end
