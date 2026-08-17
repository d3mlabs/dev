# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "../command"

module Dev
  module Cli
    # The `dev` / `dev --help` usage view. Consumes the visible commands the
    # CommandService serves (never the repository) and renders the flat
    # listing; grouped sections (a category on the builtin base) would slot
    # in here when the usage-groups work lands.
    class UsagePrinter
      extend T::Sig

      sig { params(argv: T::Array[String]).returns(T::Boolean) }
      def show_usage?(argv)
        argv.empty? || argv == ["--help"] || argv == ["-h"]
      end

      # @param project_name [String] the dev.yml `name:`
      # @param commands [Hash{String => Dev::Command}] visible commands, in
      #   listing order
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(project_name: String, commands: T::Hash[String, Command], out: T.any(IO, StringIO)).void }
      def print(project_name:, commands:, out:)
        out.puts "Usage: dev <command> [args...]"
        out.puts ""
        out.puts "Commands for #{project_name}:"
        if commands.empty?
          out.puts "  (no commands defined)"
        else
          commands.each do |cmd_name, command|
            out.puts "  #{cmd_name.ljust(12)} #{command.desc}"
          end
        end
        out.puts ""
        out.puts "Examples: dev up    dev up -v    dev update-deps    dev test"
      end
    end
  end
end
