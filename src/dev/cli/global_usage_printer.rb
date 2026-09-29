# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/command"

module Dev
  module Cli
    # The usage view for help outside a project (bare `dev`, `--help`, `-h`,
    # `help` with no dev.yml in the cwd's ancestry): the global builtins that
    # work from any directory, plus the hint that project commands need a
    # dev.yml. A dedicated view rather than a UsagePrinter variant — that
    # printer is shaped around a project catalog (project name, sections),
    # and this listing is a flat set.
    class GlobalUsagePrinter
      extend T::Sig

      # @param commands [Hash{String => Dev::Command}] the global command tree
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(commands: T::Hash[String, Command], out: T.any(IO, StringIO)).void }
      def print(commands:, out:)
        out.puts "Usage: dev <command> [args...]"
        out.puts ""
        out.puts "Global commands (available anywhere):"
        commands.sort.each do |name, command|
          next if command.hidden?

          # Groups carry the `…` marker so the listing reads as a tree: the
          # name alone is not (usually) runnable, its children are.
          label = command.children.empty? ? name : "#{name} …"
          out.puts "  #{label.ljust(12)} #{command.desc}"
        end
        out.puts ""
        out.puts "Run dev inside a project that defines a dev.yml to see its commands."
      end
    end
  end
end
