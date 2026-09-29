# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "cli/usage_printer"
require_relative "command"

module Dev
  # The group arm of CommandExecutor: a group invoked bare has nothing to
  # run, so its execution is its usage.
  class GroupExecutor
    extend T::Sig

    sig { params(usage_printer: Cli::UsagePrinter, out: T.any(IO, StringIO)).void }
    def initialize(usage_printer:, out:)
      @usage_printer = usage_printer
      @out = out
    end

    # Print the group's usage.
    #
    # @param group [CommandGroup]
    # @return [void]
    sig { params(group: CommandGroup).void }
    def execute(group)
      @usage_printer.print_node(path: group.path, command: group, out: @out)
    end
  end
end
