# typed: strict
# frozen_string_literal: true

require "dev/cli/builtins/skills_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev skills sync`: re-materialize every skill channel from what its
      # producer declares right now.
      class SkillsSyncCommand < SkillsVerbCommand
        extend T::Sig

        USAGE = "usage: dev skills sync"

        sig { override.returns(String) }
        def desc
          "Re-materialize every skill channel (dev's own, org, the project's gems) now"
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise Dev::Skills::Accessor::UsageError, USAGE unless args.positionals.empty?

          @accessor_factory.call(context.ui).sync
        end
      end
    end
  end
end
