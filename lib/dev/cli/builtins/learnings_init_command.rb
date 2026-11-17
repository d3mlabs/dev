# typed: strict
# frozen_string_literal: true

require "dev/cli/builtins/learnings_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev learnings init [--org | --gitignore]`: scaffold this repo's empty
      # learnings index and ensure its .gitignore carries dev's managed
      # footprint; with --org the org knowledge-repo layout (index.md +
      # skills/); with --gitignore only the .gitignore step. Write-once on the
      # index: an existing one is left untouched.
      class LearningsInitCommand < LearningsVerbCommand
        extend T::Sig

        USAGE = "usage: dev learnings init [--org | --gitignore]"
        ORG_FLAG = "--org"
        GITIGNORE_FLAG = "--gitignore"

        sig { override.returns(String) }
        def desc
          "Scaffold this repo's learnings index and .gitignore footprint, leaving an existing index untouched"
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [
            Cli::Flag.new(ORG_FLAG, desc: "scaffold the org knowledge repo's layout instead (index.md and skills/)"),
            Cli::Flag.new(GITIGNORE_FLAG, desc: "only the .gitignore step"),
          ]
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          org = args.flag?(ORG_FLAG)
          gitignore_only = args.flag?(GITIGNORE_FLAG)
          raise Dev::Learnings::Accessor::UsageError, USAGE unless args.positionals.empty? && !(org && gitignore_only)

          @accessor_factory.call(context.ui).init(org: org, gitignore_only: gitignore_only)
        end
      end
    end
  end
end
