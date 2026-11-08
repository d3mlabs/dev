# typed: strict
# frozen_string_literal: true

require "cli/ui"
require "stringio"

module Dev
  module Cli
    # The UI vocabulary of dev's own output. A project command gets a
    # colored header before dev execs into it and handles its own UI from
    # there; a lifecycle verb (`release`, `deploy`, dev#514) speaks this
    # vocabulary: a timed **frame** around a stage, a **step** per action
    # under a spinner, a **confirm** before anything irreversible, and
    # **say** for a formatted line — so every verb reads the same way,
    # and the way `bin/release.rb` did.
    #
    # Two tiers: UiImpl (TTY/CI — CLI::UI) and NoUi (pipe/file/tests —
    # plain lines, nobody to ask).
    module Ui
      extend T::Sig
      extend T::Helpers

      interface!

      # What the crossing line says before the destination.
      CROSSING_PREFIX = "→ "

      sig { abstract.params(command: String).void }
      def print_header(command); end

      # The one line about where a command or verb runs, printed only at
      # a crossing — when it leaves this machine for a build host over a
      # snapshot of the tree (dev#409, dev#420, dev#421): where it went
      # and from which commit, `→ on ue-engine-hosted, snapshot
      # 3f2a1c9d8e7b`, `→ in snappy-linux (container), snapshot …`. Dim: a
      # note under the header, not a header. Native and host runs print
      # nothing.
      #
      # @param destination [String] the transport's name for where (Transport#destination)
      # @param snapshot [String] the snapshot's short sha
      sig { abstract.params(destination: String, snapshot: String).void }
      def print_remote_crossing(destination:, snapshot:); end

      # Ask for a secret at the terminal, input hidden. nil when there is
      # no terminal to ask at (a pipe, CI): the caller falls back to its
      # headless path — it never blocks on a prompt nobody will see.
      #
      # @param question [String]
      # @return [String, nil] the answer ("" when the user just pressed Enter)
      sig { abstract.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question); end

      # A titled, timed frame around a stage of a verb; the block's
      # output nests inside it.
      #
      # @param title [String]
      # @yieldreturn the block's value, answered
      sig { abstract.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block); end

      # One action of a stage, named for what it does, under a spinner:
      # ✓ when the block returns, ✗ when it raises — and the raise comes
      # back out as itself, so the verb's own failure path runs (a step
      # that swallowed its failure once cascaded a tag that never reached
      # GitHub into a published formula, v0.2.73).
      #
      # @param name [String] in the progressive: "Pushing main + tag v1.2.0"
      # @yieldreturn the block's value, answered
      sig { abstract.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block); end

      # Ask yes or no at the terminal. nil when there is no terminal to
      # ask at (a pipe, CI): the caller decides what that means — a verb
      # about to do something irreversible refuses rather than assume.
      #
      # @param question [String]
      # @return [Boolean, nil]
      sig { abstract.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question); end

      # One formatted line, CLI::UI's markup (`{{bold:…}}`, `{{v}}`).
      #
      # @param text [String]
      sig { abstract.params(text: String).void }
      def say(text); end
    end

    class UiImpl
      extend T::Sig
      include Ui

      # @param cli_ui [Class] CLI::UI
      # @param prompt [Class] CLI::UI::Prompt (injectable for tests)
      # @param frame [Class] CLI::UI::Frame (injectable for tests)
      # @param spinner [Class] CLI::UI::Spinner (injectable for tests)
      # @param input [IO, StringIO] what the prompt would read: a terminal, or not
      sig do
        params(
          cli_ui: T.class_of(CLI::UI),
          prompt: T.class_of(CLI::UI::Prompt),
          frame: T.class_of(CLI::UI::Frame),
          spinner: T.class_of(CLI::UI::Spinner),
          input: T.any(IO, StringIO),
        ).void
      end
      def initialize(cli_ui:, prompt: CLI::UI::Prompt, frame: CLI::UI::Frame, spinner: CLI::UI::Spinner, input: $stdin)
        @cli_ui = cli_ui
        @prompt = prompt
        @frame = frame
        @spinner = spinner
        @input = input
        @cli_ui.enable_color = true
      end

      sig { override.params(command: String).void }
      def print_header(command)
        @cli_ui.puts(@cli_ui.fmt("{{bold:#{command}}}"))
      end

      sig { override.params(destination: String, snapshot: String).void }
      def print_remote_crossing(destination:, snapshot:)
        @cli_ui.puts(@cli_ui.fmt("{{gray:#{CROSSING_PREFIX}#{destination}, snapshot #{snapshot}}}"))
      end

      sig { override.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question)
        return nil unless @input.tty?

        @prompt.ask_password(question)
      end

      sig { override.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block)
        @frame.open(title, timing: true, &block)
      end

      # The spinner swallows the block's raise and answers false
      # (auto_debrief off: no backtrace dump — the verb reports the
      # failure in its own words); the raise is kept and re-raised.
      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block)
        result = T.let(nil, T.nilable(T.type_parameter(:T)))
        failure = T.let(nil, T.nilable(StandardError))
        @spinner.spin(name, auto_debrief: false) do
          result = block.call
        rescue StandardError => e
          failure = e
          raise
        end
        raise failure if failure

        T.cast(result, T.type_parameter(:T))
      end

      sig { override.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question)
        return nil unless @input.tty?

        @prompt.confirm(question)
      end

      sig { override.params(text: String).void }
      def say(text)
        @cli_ui.puts(@cli_ui.fmt(text))
      end
    end

    class NoUi
      extend T::Sig
      include Ui

      # @param out [IO, StringIO, nil] where the plain lines go; nil is
      #   stdout as it stands at each write
      sig { params(out: T.nilable(T.any(IO, StringIO))).void }
      def initialize(out: nil)
        @out = out
      end

      sig { override.params(command: String).void }
      def print_header(command)
        out.puts(command)
      end

      sig { override.params(destination: String, snapshot: String).void }
      def print_remote_crossing(destination:, snapshot:)
        out.puts("#{CROSSING_PREFIX}#{destination}, snapshot #{snapshot}")
      end

      sig { override.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question)
        nil
      end

      sig { override.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block)
        out.puts(title)
        block.call
      end

      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block)
        result = block.call
        out.puts("#{CLI::UI::Glyph::CHECK.char} #{name}")
        result
      rescue StandardError
        out.puts("#{CLI::UI::Glyph::X.char} #{name}")
        raise
      end

      sig { override.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question)
        nil
      end

      sig { override.params(text: String).void }
      def say(text)
        out.puts(CLI::UI.fmt(text, enable_color: false))
      end

      private

      sig { returns(T.any(IO, StringIO)) }
      def out = @out || $stdout
    end
  end
end
