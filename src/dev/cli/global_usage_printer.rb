# typed: strict
# frozen_string_literal: true

require "stringio"

module Dev
  module Cli
    # The usage view for help outside a project (bare `dev`, `--help`, `-h`,
    # `help` with no dev.yml in the cwd's ancestry): the global builtins that
    # work from any directory, plus the hint that project commands need a
    # dev.yml. A dedicated view rather than a UsagePrinter variant — that
    # printer is shaped around a project catalog (project name, sections),
    # and this listing is a flat, fixed set.
    class GlobalUsagePrinter
      extend T::Sig

      # @param commands [Hash{String => String}] global command name => description
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(commands: T::Hash[String, String], out: T.any(IO, StringIO)).void }
      def print(commands:, out:)
        out.puts "Usage: dev <command> [args...]"
        out.puts ""
        out.puts "Global commands (available anywhere):"
        commands.sort.each do |name, desc|
          out.puts "  #{name.ljust(12)} #{desc}"
        end
        out.puts ""
        out.puts "Run dev inside a project that defines a dev.yml to see its commands."
      end
    end
  end
end
