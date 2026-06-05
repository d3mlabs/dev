# frozen_string_literal: true

require_relative "dependency_installer"

module Dev
  module Deps
    # Command registry for dependency management commands built into dev.
    #
    # The runner checks BuiltinCommands.builtin? before YAML lookup. If a
    # project defines the same command name, the project command runs after
    # the built-in. All lifecycle logic lives in DepsOrchestrator.
    module BuiltinCommands
      COMMANDS = %w[update-deps].freeze

      # Check if a command name is a built-in dependency command.
      #
      # @param command_name [String]
      # @return [Boolean]
      def self.builtin?(command_name)
        COMMANDS.include?(command_name)
      end
    end
  end
end
