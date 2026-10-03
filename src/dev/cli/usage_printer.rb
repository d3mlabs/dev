# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "../command"

module Dev
  module Cli
    # The usage view of any node of the command tree — what a group prints
    # when invoked bare (the root included: bare `dev`), and what
    # `dev help <path…>` prints for any node: how to invoke it, its
    # description, and its visible children. Children render as sections
    # keyed by their Category trait when they span more than one (the
    # root's listing: the project's own commands, then the Lifecycle and
    # Development flow builtins); as one plain list otherwise. Alphabetical
    # within a section, so the listing is deterministic regardless of
    # registration order.
    class UsagePrinter
      extend T::Sig

      # Section headings, in listing order.
      HEADINGS = T.let(
        {
          Command::Category::Project => "Project commands",
          Command::Category::Lifecycle => "Lifecycle",
          Command::Category::Workflow => "Development flow",
        }.freeze,
        T::Hash[Command::Category, String],
      )

      # @param epilogue [String, nil] the root usage's closing line
      #   (examples, or the hint that project commands need a dev.yml) —
      #   the one line that is about the tool rather than a node
      sig { params(epilogue: T.nilable(String)).void }
      def initialize(epilogue: nil)
        @epilogue = epilogue
      end

      # @param path [Array<String>] the path that reached the node (empty
      #   for the root)
      # @param command [Dev::Command]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(path: T::Array[String], command: Command, out: T.any(IO, StringIO)).void }
      def print_node(path:, command:, out:)
        invocation = ["dev", *path].join(" ")
        children = command.children.reject { |_name, child| child.hidden? }.to_a
        out.puts "Usage: #{invocation} [args...]" unless command.is_a?(CommandGroup)
        out.puts "#{command.is_a?(CommandGroup) ? "Usage:" : "      "} #{invocation} <command> [args...]" unless children.empty?
        out.puts ""
        out.puts command.desc
        print_children(children, out) unless children.empty?
        return if path.any? || @epilogue.nil?

        out.puts ""
        out.puts @epilogue
      end

      private

      # One "Commands:" list when the children share a category; headed
      # sections in HEADINGS order otherwise (categories with no children
      # are omitted — some builtins are config-gated, e.g. `container`).
      #
      # @param children [Array<[String, Dev::Command]>] the visible children
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(children: T::Array[[String, Command]], out: T.any(IO, StringIO)).void }
      def print_children(children, out)
        sections = children.group_by { |_name, child| child.category }
        return print_section("Commands", children, out) if sections.size == 1

        HEADINGS.each do |category, heading|
          section = sections[category]
          print_section(heading, section, out) if section
        end
      end

      # @param heading [String]
      # @param commands [Array<[String, Dev::Command]>]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(heading: String, commands: T::Array[[String, Command]], out: T.any(IO, StringIO)).void }
      def print_section(heading, commands, out)
        out.puts ""
        out.puts "#{heading}:"
        # Nodes with children carry a trailing ellipsis: the reader learns
        # there is more beneath without the listing expanding the whole tree.
        commands.sort_by { |name, _command| name }.each do |name, command|
          label = command.children.empty? ? name : "#{name} …"
          out.puts "  #{label.ljust(12)} #{command.desc}"
        end
      end
    end
  end
end
