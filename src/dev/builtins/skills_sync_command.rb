# typed: strict
# frozen_string_literal: true

require "dev/builtins/skills_verb_command"

module Dev
  module Builtins
    # `dev skills sync`: re-materialize every skill channel from what its
    # producer declares right now.
    class SkillsSyncCommand < SkillsVerbCommand
      extend T::Sig

      USAGE = "usage: dev skills sync"

      sig { override.returns(String) }
      def desc = "Re-materialize every skill channel (dev's own, org, the project's gems) now"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Skills::Accessor::UsageError, USAGE unless args.empty?

        @accessor_factory.call.sync(out: @out)
      end
    end
  end
end
