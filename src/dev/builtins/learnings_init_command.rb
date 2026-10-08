# typed: strict
# frozen_string_literal: true

require "dev/builtins/learnings_verb_command"

module Dev
  module Builtins
    # `dev learnings init [--org | --gitignore]`: scaffold this repo's empty
    # learnings index and ensure its .gitignore carries dev's managed
    # footprint; with --org the org knowledge-repo layout (index.md +
    # skills/); with --gitignore only the .gitignore step. Write-once on the
    # index: an existing one is left untouched.
    class LearningsInitCommand < LearningsVerbCommand
      extend T::Sig

      USAGE = "usage: dev learnings init [--org | --gitignore]"

      sig { override.returns(String) }
      def desc = "Scaffold this repo's learnings index + .gitignore footprint, or the org layout (--org); write-once"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        flags = args.dup
        org = flags.delete("--org") ? true : false
        gitignore_only = flags.delete("--gitignore") ? true : false
        raise Dev::Learnings::Accessor::UsageError, USAGE unless flags.empty? && !(org && gitignore_only)

        @accessor_factory.call.init(out: @out, org: org, gitignore_only: gitignore_only)
      end
    end
  end
end
