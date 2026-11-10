# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/environment_image"
require_relative "command"
require_relative "host_rule"
require_relative "placement"
require_relative "flag_vocabulary"

module Dev
  module Cli
    # The usage view of any node of the command tree — what a group prints
    # when invoked bare (the root included: bare `dev`), and what
    # `dev help <path…>` prints for any node: how to invoke it, its
    # description, and its visible children. Children render as sections
    # keyed by their Category trait when they span more than one (the
    # root's listing: the project's own commands, then the Lifecycle verbs,
    # the Environment and the Development flow builtins); as one plain list
    # otherwise. Alphabetical
    # within a section, so the listing is deterministic regardless of
    # registration order. A node's own flags list after its description, in
    # the order the command declares them — the command carries its
    # documentation where the operator meets it.
    #
    # Every command with a project body — a project command, a builtin a
    # project overrode — also says where it runs on this machine (dev#409):
    # a dim trailing column on its listing row, a sentence in its own
    # usage. The environment is the command's bound placement under the
    # host rule: `host`, the image's name, or the image's name with
    # `(container)` when running it from here enters a container. A
    # builtin with no project body runs on the host by construction and is
    # not annotated. A lifecycle verb's own usage lists what it acts on
    # (LifecycleCommand#listing — the builds, for `build` and `package`)
    # in the same three columns, each with the environment its target
    # declares for it — with `(remote)` rather than `(container)` where
    # this machine is not that environment, since a verb never enters a
    # container: it leaves for a host that is (the remote dispatch — a
    # runner, dev#420, or the project's own container, dev#421), and which
    # one is decided when it runs, never asked of the forge by help.
    class UsagePrinter
      extend T::Sig

      # Section headings, in listing order.
      HEADINGS = T.let(
        {
          Command::Category::Project => "Project commands",
          Command::Category::Lifecycle => "Lifecycle",
          Command::Category::Environment => "Environment",
          Command::Category::Workflow => "Development flow",
        }.freeze,
        T::Hash[Command::Category, String],
      )

      # What the environment column appends to an image's name when
      # running it from here enters a container of it.
      CONTAINER_SUFFIX = " (container)"
      # …and when a lifecycle verb over it leaves for a host that is it.
      REMOTE_SUFFIX = " (remote)"

      # The label column of a command section: wide enough for a command
      # name, so the summaries line up across sections.
      LABEL_WIDTH = 12

      # One line of a headed block — a command's or a verb subject's — and
      # the detail lines that follow it.
      class Row < T::Struct
        const :label, String
        const :summary, String
        const :environment, T.nilable(String), default: nil
        const :details, T::Array[String], default: []
      end

      # @param epilogue [String, nil] the root usage's closing line
      #   (examples, or the hint that project commands need a dev.yml) —
      #   the one line that is about the tool rather than a node
      # @param host_rule [Dev::Cli::HostRule] whether an image's work crosses
      #   into a container from this machine — what the environment column
      #   reads, so it agrees with where the command runner places it
      sig { params(epilogue: T.nilable(String), host_rule: HostRule).void }
      def initialize(epilogue: nil, host_rule: HostRule.new)
        @epilogue = epilogue
        @host_rule = host_rule
      end

      # @param path [Array<String>] the path that reached the node (empty
      #   for the root)
      # @param command [Dev::Cli::Command]
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
        sentence = environment_sentence(command)
        out.puts sentence if sentence
        details(command).each { |line| out.puts line }
        print_flags(command.flags, out) unless command.flags.empty?
        listing = command.is_a?(LifecycleCommand) ? command.listing : nil
        print_listing(listing, out) if listing
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
      # @param children [Array<[String, Dev::Cli::Command]>] the visible children
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
      # @param commands [Array<[String, Dev::Cli::Command]>]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(heading: String, commands: T::Array[[String, Command]], out: T.any(IO, StringIO)).void }
      def print_section(heading, commands, out)
        rows = commands.sort_by { |name, _command| name }.map do |name, command|
          # Nodes with children carry a trailing ellipsis: the reader learns
          # there is more beneath without the listing expanding the whole tree.
          label = command.children.empty? ? name : "#{name} …"
          Row.new(label:, summary: summary(command), environment: environment_label(command), details: details(command))
        end
        print_rows(heading, rows, out, label_width: LABEL_WIDTH)
      end

      # A lifecycle verb's subjects (LifecycleCommand#listing) in the same
      # three columns as a command section, in the verb's order — the
      # builds as declared, which is what makes the first one the bare
      # verb's default. The environment is the subject's placement under
      # the host rule, as a command's is, with the verb's note when this
      # machine cannot produce the build there.
      #
      # @param listing [Dev::Cli::LifecycleCommand::Listing]
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(listing: LifecycleCommand::Listing, out: T.any(IO, StringIO)).void }
      def print_listing(listing, out)
        rows = listing.subjects.map do |subject|
          environment = [placement_label(subject.placement, lifecycle: true), subject.note].compact.join(" ")
          Row.new(label: subject.name, summary: subject.desc, environment: environment.empty? ? nil : environment)
        end
        # Build names run long (`cellbound-3d-steamworks-win64-release`), so
        # the label column fits the longest rather than a command name's.
        label_width = rows.map { |row| row.label.length }.max || LABEL_WIDTH
        print_rows(listing.heading, rows, out, label_width: [LABEL_WIDTH, label_width].max)
      end

      # One headed block of rows: labels padded to the given width, the
      # summary column to the longest summary, the environment dim and
      # last; a row with no environment ends at its summary. A row's
      # details follow it, indented to the summary column.
      #
      # @param heading [String]
      # @param rows [Array<Row>]
      # @param out [IO, StringIO]
      # @param label_width [Integer]
      # @return [void]
      sig { params(heading: String, rows: T::Array[Row], out: T.any(IO, StringIO), label_width: Integer).void }
      def print_rows(heading, rows, out, label_width:)
        out.puts ""
        out.puts "#{heading}:"
        summary_width = T.must(rows.map { |row| row.summary.length }.max)
        rows.each do |row|
          prefix = "  #{row.label.ljust(label_width)} "
          environment = row.environment
          out.puts(environment ? "#{prefix}#{row.summary.ljust(summary_width)}  #{dim(environment, out)}" : "#{prefix}#{row.summary}")
          row.details.each { |line| out.puts "#{" " * prefix.length}#{line}" }
        end
      end

      # A verb's detail lines (LifecycleCommand#details); nothing for the
      # other shapes.
      #
      # @param command [Dev::Cli::Command]
      # @return [Array<String>]
      sig { params(command: Command).returns(T::Array[String]) }
      def details(command)
        command.is_a?(LifecycleCommand) ? command.details : []
      end

      # A desc's first line. A multi-line desc is a summary line plus detail
      # that only the node's own usage prints (print_node puts the whole
      # desc); the parent's listing stays one line per child.
      #
      # @param command [Dev::Cli::Command]
      # @return [String]
      sig { params(command: Command).returns(String) }
      def summary(command)
        command.desc.lines.fetch(0, "").chomp
      end

      # The listing row's environment column: `host`, the image's name, or
      # the name with CONTAINER_SUFFIX when running it from here enters a
      # container (REMOTE_SUFFIX for a verb, which leaves instead). Nothing
      # for a command with no project body, and nothing for one the
      # composition root could not bind (the lock was unreadable; it said
      # so on stderr).
      #
      # @param command [Dev::Cli::Command]
      # @return [String, nil]
      sig { params(command: Command).returns(T.nilable(String)) }
      def environment_label(command)
        placement_label(placement_of(command), lifecycle: command.is_a?(LifecycleCommand))
      end

      # A placement as the column spells it; nil for none.
      #
      # @param placement [Dev::Cli::Placement, nil]
      # @param lifecycle [Boolean] whether the row is a verb's or a verb
      #   subject's — what leaves rather than enters a container
      # @return [String, nil]
      sig { params(placement: T.nilable(Placement), lifecycle: T::Boolean).returns(T.nilable(String)) }
      def placement_label(placement, lifecycle: false)
        return nil if placement.nil?

        case placement
        when Placement::Host then placement.name
        when Placement::Image
          return placement.name unless @host_rule.enters_container?(placement.image)

          "#{placement.name}#{lifecycle ? REMOTE_SUFFIX : CONTAINER_SUFFIX}"
        else
          # simplecov:disable — the sealed placement has no third shape;
          # T.absurd keeps the static proof.
          T.absurd(placement)
          # simplecov:enable
        end
      end

      # The node's own usage says the same in a sentence.
      #
      # @param command [Dev::Cli::Command]
      # @return [String, nil] nil when the row would carry no column either
      sig { params(command: Command).returns(T.nilable(String)) }
      def environment_sentence(command)
        placement = placement_of(command)
        return nil if placement.nil?

        case placement
        when Placement::Host then "Runs on the host."
        when Placement::Image
          "Runs in #{placement.name}, #{where(placement.image, lifecycle: command.is_a?(LifecycleCommand))}."
        else
          # simplecov:disable — see environment_label.
          T.absurd(placement)
          # simplecov:enable
        end
      end

      # Where an image's body runs from here, for the sentence.
      #
      # @param image [Dev::EnvironmentImage]
      # @param lifecycle [Boolean] as for placement_label
      # @return [String]
      sig { params(image: EnvironmentImage, lifecycle: T::Boolean).returns(String) }
      def where(image, lifecycle:)
        return "natively on this machine" unless @host_rule.enters_container?(image)

        lifecycle ? "on a remote host (this machine was not provisioned from it)" : "in a container on this machine"
      end

      # The bound placement of a command with a project body, or of a verb
      # whose seam runs in one place (a channel's protocol); nil for the
      # shapes that have none (a builtin, a group, a verb placed per build).
      #
      # @param command [Dev::Cli::Command]
      # @return [Dev::Cli::Placement, nil]
      sig { params(command: Command).returns(T.nilable(Placement)) }
      def placement_of(command)
        case command
        when ProjectCommand then command.placement
        when OverriddenCommand then command.project.placement
        when LifecycleCommand then command.placement
        else nil
        end
      end

      # Dim on a terminal; plain text anywhere else (a pipe, a test's
      # StringIO), so the column never leaks escape codes into a capture.
      #
      # @param text [String]
      # @param out [IO, StringIO]
      # @return [String]
      sig { params(text: String, out: T.any(IO, StringIO)).returns(String) }
      def dim(text, out)
        out.tty? ? "\e[2m#{text}\e[0m" : text
      end
    end
  end
end
