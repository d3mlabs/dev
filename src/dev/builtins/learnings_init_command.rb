# typed: strict
# frozen_string_literal: true

require "dev/builtins/learnings_verb_command"

module Dev
  module Builtins
    # `dev learnings init [--org]`: scaffold this repo's empty learnings index,
    # or with --org the org knowledge-repo layout (index.md + skills/).
    # Write-once: an existing index is left untouched.
    class LearningsInitCommand < LearningsVerbCommand
      extend T::Sig

      USAGE = "usage: dev learnings init [--org]"

      sig { override.returns(String) }
      def desc = "Scaffold this repo's learnings index, or the org knowledge-repo layout (--org); write-once"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        flags = args.dup
        org = flags.delete("--org") ? true : false
        raise Dev::Learnings::Accessor::UsageError, USAGE unless flags.empty?

        @accessor_factory.call.init(out: @out, org: org)
      end
    end
  end
end
