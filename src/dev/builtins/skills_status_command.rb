# typed: strict
# frozen_string_literal: true

require "dev/builtins/skills_verb_command"

module Dev
  module Builtins
    # `dev skills status [--json]`: every channel's root and materialized
    # links, with package/version provenance where the channel knows it.
    class SkillsStatusCommand < SkillsVerbCommand
      extend T::Sig

      USAGE = "usage: dev skills status [--json]"
      JSON_FLAG = "--json"

      sig { override.returns(String) }
      def desc = "Show every skill channel: where its links land, what is linked, and from which package/version"

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        raise Dev::Skills::Accessor::UsageError, USAGE unless args.empty? || args == [JSON_FLAG]

        @accessor_factory.call.status(out: @out, json: args.include?(JSON_FLAG))
      end
    end
  end
end
