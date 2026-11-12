# typed: strict
# frozen_string_literal: true

require "dev/cli/command"
require "dev/plan"
require "dev/ui"
require "dev/cli/workspace_root"

module Dev
  module Cli
    module Builtins
      # The shape every `dev plan <verb>` leaf shares: the accessor is built
      # per call over the context's Ui, anchored at the enclosing workspace
      # (nearest dev.yml, else git root, else the cwd — a global command runs
      # from any directory), the host hook point runs first (shipped skill
      # links + org learnings artifacts, see Plan::Accessor#refresh_host),
      # then the verb. Subclasses own the verb: its argv shape and which
      # accessor method it calls.
      class PlanVerbCommand < BuiltinCommand
        extend T::Sig
        extend T::Helpers

        abstract!

        # Builds the accessor over the Ui the verb speaks through.
        AccessorFactory = T.type_alias { T.proc.params(ui: Dev::Ui).returns(Dev::Plan::Accessor) }

        # Target the org plans repo instead of the enclosing project's. Shared
        # by every verb that resolves a repo.
        ORG_FLAG = "--org"

        # The production factory; a constant so its wiring is testable apart
        # from any verb.
        DEFAULT_ACCESSOR_FACTORY = T.let(
          ->(ui) { Dev::Plan::Accessor.new(project_root: WorkspaceRoot.workspace, ui:) },
          AccessorFactory,
        )

        sig { params(accessor_factory: AccessorFactory).void }
        def initialize(accessor_factory: DEFAULT_ACCESSOR_FACTORY)
          super()
          @accessor_factory = accessor_factory
        end

        sig { override.returns(Command::Category) }
        def category
          Command::Category::Workflow
        end

        # plan never touches dependencies and runs headlessly from Cursor
        # hooks, where a staleness warning would only add noise.
        sig { override.returns(T::Boolean) }
        def staleness_exempt?
          true
        end

        sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).void }
        def call(args:, context:)
          accessor = @accessor_factory.call(context.ui)
          accessor.refresh_host
          perform(accessor, args)
        end

        private

        # The verb itself, after the host refresh.
        #
        # @param accessor [Dev::Plan::Accessor] anchored at the workspace
        # @param args [Cli::ParsedArgs] the parsed args after the verb
        # @return [void]
        sig { abstract.params(accessor: Dev::Plan::Accessor, args: Cli::ParsedArgs).void }
        def perform(accessor, args); end
      end
    end
  end
end
