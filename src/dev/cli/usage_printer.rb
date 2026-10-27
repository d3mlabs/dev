# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "../command"
require_relative "flag_vocabulary"

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
    # registration order. A node's own flags list after its description, in
    # the order the command declares them — the command carries its
    # documentation where the operator meets it.
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
        print_flags(command.flags, out) unless command.flags.empty?
        print_children(children, out) unless children.empty?
        return if path.any? || @epilogue.nil?

        out.puts ""
        out.puts @epilogue
      end

      # The rendering of a malformed command line at a node: the message,
      # then that node's usage, as getopt/cobra tools do. The caller owns
      # the exit status.
      #
      # @param error [FlagVocabulary::UsageError]
      # @param out [IO, StringIO] the diagnostics stream
      # @return [void]
      sig { params(error: FlagVocabulary::UsageError, out: T.any(IO, StringIO)).void }
      def print_usage_error(error, out:)
        out.puts "dev: #{error.message}"
        print_node(path: error.path, command: error.command, out:)
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

      # The node's flags, one per line, in declaration order: a value-taking
      # flag shows a `<value>` placeholder; descriptions align in one column
      # sized to the longest label, and an undescribed flag lists by its
      # label alone.
      #
      # @param flags [Array<Dev::Cli::Flag>]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(flags: T::Array[Flag], out: T.any(IO, StringIO)).void }
      def print_flags(flags, out)
        labels = flags.map { |flag| flag.takes_value? ? "#{flag.name} <value>" : flag.name }
        width = T.must(labels.map(&:length).max)
        out.puts ""
        out.puts "Flags:"
        flags.zip(labels).each do |flag, label|
          out.puts "  #{T.must(label).ljust(width)}  #{flag.desc}".rstrip
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
          out.puts "  #{label.ljust(12)} #{summary(command)}"
        end
      end

      # A desc's first line. A multi-line desc is a summary line plus detail
      # that only the node's own usage prints (print_node puts the whole
      # desc); the parent's listing stays one line per child.
      #
      # @param command [Dev::Command]
      # @return [String]
      sig { params(command: Command).returns(String) }
      def summary(command)
        command.desc.lines.fetch(0, "").chomp
      end
    end
  end
end
