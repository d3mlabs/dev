# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "../command"

module Dev
  module Cli
    # The usage view the help builtin renders. Consumes the visible commands
    # the CommandService serves (never the repository) and renders them as
    # sections keyed by each command's Category trait: the project's own
    # commands first, then the Lifecycle and Development flow builtins.
    # Alphabetical within a section, so the listing is deterministic
    # regardless of registration order.
    class UsagePrinter
      extend T::Sig

      # @param project_name [String] the dev.yml `name:`
      # @param commands [Hash{String => Dev::Command}] visible commands
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(project_name: String, commands: T::Hash[String, Command], out: T.any(IO, StringIO)).void }
      def print(project_name:, commands:, out:)
        sections = commands.group_by { |_name, command| command.category }

        out.puts "Usage: dev <command> [args...]"
        out.puts ""
        out.puts "Commands for #{project_name}:"
        project_commands = sections.fetch(Command::Category::Project, [])
        if project_commands.empty?
          out.puts "  (no commands defined)"
        else
          print_commands(project_commands, out)
        end
        print_section("Lifecycle", sections.fetch(Command::Category::Lifecycle, []), out)
        print_section("Development flow", sections.fetch(Command::Category::Workflow, []), out)
        out.puts ""
        out.puts "Examples: dev up    dev up -v    dev update-deps    dev test"
      end

      # The usage view of one node — what a group prints when invoked bare,
      # and what `dev help <path>` prints for any node: how to invoke it (a
      # runnable node with children has two forms), its description, and
      # its visible children when it has any.
      #
      # @param path [Array<String>] the path that reached the node
      # @param command [Dev::Command]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(path: T::Array[String], command: Command, out: T.any(IO, StringIO)).void }
      def print_node(path:, command:, out:)
        invocation = "dev #{path.join(" ")}"
        children = command.children.reject { |_name, child| child.hidden? }.to_a
        out.puts "Usage: #{invocation} [args...]" unless command.is_a?(CommandGroup)
        out.puts "#{command.is_a?(CommandGroup) ? "Usage:" : "      "} #{invocation} <command> [args...]" unless children.empty?
        out.puts ""
        out.puts command.desc
        return if children.empty?

        out.puts ""
        out.puts "Commands:"
        print_commands(children, out)
      end

      private

      # Render one builtin section; sections with no commands are omitted
      # entirely (some builtins are config-gated, e.g. reset-container).
      #
      # @param heading [String]
      # @param commands [Array<[String, Dev::Command]>]
      # @param out [IO, StringIO]
      # @return [void]
      sig do
        params(
          heading: String,
          commands: T::Array[[String, Command]],
          out: T.any(IO, StringIO),
        ).void
      end
      def print_section(heading, commands, out)
        return if commands.empty?

        out.puts ""
        out.puts "#{heading}:"
        print_commands(commands, out)
      end

      # Nodes with children carry a trailing ellipsis: the reader learns
      # there is more beneath without the listing expanding the whole tree.
      #
      # @param commands [Array<[String, Dev::Command]>]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(commands: T::Array[[String, Command]], out: T.any(IO, StringIO)).void }
      def print_commands(commands, out)
        commands.sort_by { |name, _command| name }.each do |name, command|
          label = command.children.empty? ? name : "#{name} …"
          out.puts "  #{label.ljust(12)} #{command.desc}"
        end
      end
    end
  end
end
