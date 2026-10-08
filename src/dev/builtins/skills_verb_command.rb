# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"
require "dev/host_service"
require "dev/skills"
require "dev/workspace_root"

module Dev
  module Builtins
    # The shape every `dev skills <verb>` leaf shares: the accessor is built
    # per call over every channel HostService composes for the enclosing
    # project (nearest dev.yml, else git root; nil outside any checkout,
    # where only the user-global channels exist). Subclasses own the verb:
    # its argv shape and which accessor method it calls.
    class SkillsVerbCommand < BuiltinCommand
      extend T::Sig
      extend T::Helpers

      abstract!

      AccessorFactory = T.type_alias { T.proc.returns(Dev::Skills::Accessor) }

      # The production factory; a constant so its wiring is testable apart
      # from any verb.
      DEFAULT_ACCESSOR_FACTORY = T.let(
        lambda do
          project_root = WorkspaceRoot.enclosing_project
          channels = Dev::HostService.new.skill_channels(project_root: project_root)
          Dev::Skills::Accessor.new(channels: channels, project_root: project_root)
        end,
        AccessorFactory,
      )

      sig { params(accessor_factory: AccessorFactory, out: T.any(IO, StringIO)).void }
      def initialize(accessor_factory: DEFAULT_ACCESSOR_FACTORY, out: $stdout)
        super()
        @accessor_factory = accessor_factory
        @out = out
      end

      sig { override.returns(Command::Category) }
      def category = Command::Category::Workflow

      # Host-global: a project's dependency staleness is irrelevant.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true
    end
  end
end
