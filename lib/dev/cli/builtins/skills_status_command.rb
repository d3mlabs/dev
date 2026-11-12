# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/builtins/skills_verb_command"

module Dev
  module Cli
    module Builtins
      # `dev skills status [--json]`: every channel's root and materialized
      # links, with package/version provenance where the channel knows it —
      # through the Ui, or as a bare JSON payload on its stream with `--json`.
      class SkillsStatusCommand < SkillsVerbCommand
        extend T::Sig

        USAGE = "usage: dev skills status [--json]"
        JSON_FLAG = "--json"

        sig { params(accessor_factory: AccessorFactory, out: T.any(IO, StringIO)).void }
        def initialize(accessor_factory: DEFAULT_ACCESSOR_FACTORY, out: $stdout)
          super(accessor_factory:)
          @out = out
        end

        sig { override.returns(String) }
        def desc
          "Show every skill channel: where its links land, what is linked, and from which package/version"
        end

        sig { override.returns(T::Array[Cli::Flag]) }
        def flags
          [Cli::Flag.new(JSON_FLAG)]
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          raise Dev::Skills::Accessor::UsageError, USAGE if args.positionals.any?

          accessor = @accessor_factory.call(context.ui)
          if args.flag?(JSON_FLAG)
            accessor.status_json(out: @out)
          else
            accessor.status
          end
        end
      end
    end
  end
end
