# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/builtins/learnings_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev learnings invariants`: print the always-on org invariants block
      # (the Tier-0 prompt seam). A payload command: the block goes bare to
      # its stream, never through the Ui — consumers parse it.
      class LearningsInvariantsCommand < LearningsVerbCommand
        extend T::Sig

        USAGE = "usage: dev learnings invariants"

        sig { params(accessor_factory: AccessorFactory, out: T.any(IO, StringIO)).void }
        def initialize(accessor_factory: DEFAULT_ACCESSOR_FACTORY, out: $stdout)
          super(accessor_factory:)
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "Print the always-on org invariants block (the Tier-0 prompt seam)"
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise Dev::Learnings::Accessor::UsageError, USAGE unless args.positionals.empty?

          @accessor_factory.call(context.ui).invariants(out: @out)
        end
      end
    end
  end
end
