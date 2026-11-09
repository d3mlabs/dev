# typed: strict
# frozen_string_literal: true

require "cli/ui"
require "stringio"
require "dev/terminal_owner"

module Dev
  module Cli
    # The UI vocabulary of dev's own output. A project command gets a
    # colored header before dev execs into it and handles its own UI from
    # there; a lifecycle verb (`release`, `deploy`, dev#514) speaks this
    # vocabulary — the one `bin/release.rb` had, and plans#52's: a timed
    # **frame** around a stage; a **spin** for an action under a spinner;
    # a **step** for an action that owns the terminal; a **confirm**
    # before anything irreversible; **note** for a formatted line.
    #
    # The split between spin and step is the stdio contract, learned the
    # hard way (plans#52): a spinner captures every Ruby-level write and
    # masks stdin while it animates, so only in-process work or a
    # captured subprocess (`Open3.capture3`, stdin supplied) may run
    # under one. A child that inherits the terminal — a `build:` script,
    # a publisher, anything that may prompt — runs under a step: no
    # spinner, nothing captured, its lines and prompts landing as
    # written. The rule is enforced, not reviewed: a spin owns
    # the thread's terminal (TerminalOwner), and the places dev spawns
    # with inherited stdio refuse to run under it.
    #
    # The StdoutRouter — CLI::UI's Ruby-level `$stdout` writer, which
    # prefixes each line with the open frame's bar — is turned on by the
    # first frame and stays on: cli-ui cannot turn it on twice (dev#523),
    # and with no frame open it prefixes nothing. It is Ruby-level: a
    # child's own lines are never prefixed, by any tier, and nothing
    # here pretends otherwise.
    #
    # Two tiers: UiImpl (TTY/CI — CLI::UI) and NoUi (pipe/file/tests —
    # the same facts as plain lines, no escape codes, nobody to ask).
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

      # A titled, timed frame around a stage of a verb: dev's own lines
      # inside it carry its bar (a child's do not — see above).
      #
      # @param title [String]
      # @yieldreturn the block's value, answered
      # @raise [TerminalOwner::UnderSpinnerError] under a spin
      sig { abstract.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block); end

      # One action under a spinner: ✓ when the block returns, ✗ when it
      # raises — and the raise comes back out as itself, so the verb's
      # own failure path runs (a step that swallowed its failure once
      # cascaded a tag that never reached GitHub into a published
      # formula, v0.2.73). The block is in-process work or a captured
      # subprocess; it owns the terminal for the block, so a child with
      # inherited stdio, a prompt, a frame, a step or a spin under it is
      # refused (TerminalOwner).
      #
      # @param name [String] in the progressive: "Pushing main + tag v1.2.0"
      # @yieldreturn the block's value, answered
      # @raise [TerminalOwner::UnderSpinnerError] under a spin
      sig { abstract.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def spin(name, &block); end

      # One action that owns the terminal: a child with inherited stdio
      # (a `build:` script, a publisher, `sudo`), whose lines, colors,
      # progress bars and prompts land exactly as it writes them. No
      # spinner; the name before, ✓ or ✗ after; the raise comes back out
      # as itself.
      #
      # @param name [String] in the progressive: "Packaging site-release"
      # @yieldreturn the block's value, answered
      # @raise [TerminalOwner::UnderSpinnerError] under a spin
      sig { abstract.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block); end

      # Ask yes or no at the terminal. nil when there is no terminal to
      # ask at (a pipe, CI): the caller decides what that means — a verb
      # about to do something irreversible refuses rather than assume.
      #
      # @param question [String]
      # @return [Boolean, nil]
      # @raise [TerminalOwner::UnderSpinnerError] under a spin
      sig { abstract.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question); end

      # One formatted line, CLI::UI's markup (`{{bold:…}}`, `{{v}}`).
      #
      # @param text [String]
      sig { abstract.params(text: String).void }
      def note(text); end
    end

    class UiImpl
      extend T::Sig
      include Ui

      # @param cli_ui [Class] CLI::UI
      # @param prompt [Class] CLI::UI::Prompt (injectable for tests)
      # @param frame [Class] CLI::UI::Frame (injectable for tests)
      # @param spinner [Class] CLI::UI::Spinner (injectable for tests)
      # @param router [Module] CLI::UI::StdoutRouter (injectable for tests)
      # @param input [IO, StringIO] what the prompt would read: a terminal, or not
      sig do
        params(
          cli_ui: T.class_of(CLI::UI),
          prompt: T.class_of(CLI::UI::Prompt),
          frame: T.class_of(CLI::UI::Frame),
          spinner: T.class_of(CLI::UI::Spinner),
          router: T.class_of(CLI::UI::StdoutRouter),
          input: T.any(IO, StringIO),
        ).void
      end
      def initialize(cli_ui:, prompt: CLI::UI::Prompt, frame: CLI::UI::Frame, spinner: CLI::UI::Spinner, router: CLI::UI::StdoutRouter, input: $stdin)
        @cli_ui = cli_ui
        @prompt = prompt
        @frame = frame
        @spinner = spinner
        @router = router
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
        TerminalOwner.claim!("a prompt")
        return nil unless @input.tty?

        @prompt.ask_password(question)
      end

      # The first frame turns the StdoutRouter on and it stays on for the
      # process: cli-ui's `disable` is one-way (it leaves the alias
      # `enabled?` reads, so a second `enable` refuses — dev#523), and
      # nothing needs it off — a child's fd 1 is never the Ruby-level
      # `$stdout`, and with no frame open the router prefixes nothing.
      sig { override.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block)
        TerminalOwner.claim!("a frame")
        @router.enable
        @frame.open(title, timing: true, &block)
      end

      # The spinner swallows the block's raise and answers false
      # (auto_debrief off: no backtrace dump — the verb reports the
      # failure in its own words); the raise is kept and re-raised.
      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def spin(name, &block)
        result = T.let(nil, T.nilable(T.type_parameter(:T)))
        failure = T.let(nil, T.nilable(StandardError))
        TerminalOwner.spinning do
          @spinner.spin(name, auto_debrief: false) do
            result = block.call
          rescue StandardError => e
            failure = e
            raise
          end
        end
        raise failure if failure

        T.cast(result, T.type_parameter(:T))
      end

      # The name and the glyph line are dev's (prefixed, inside a frame);
      # between them the child writes to its inherited fd 1 — never the
      # routed `$stdout` — so its lines reach the terminal untouched and a
      # prompt of its lands where the operator sees it. No spinner, nothing
      # captured (TerminalOwner).
      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block)
        TerminalOwner.claim!("a step")
        @cli_ui.puts(@cli_ui.fmt(name))
        begin
          result = block.call
        rescue StandardError
          @cli_ui.puts(@cli_ui.fmt("{{x}} #{name}"))
          raise
        end
        @cli_ui.puts(@cli_ui.fmt("{{v}} #{name}"))
        result
      end

      sig { override.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question)
        TerminalOwner.claim!("a prompt")
        return nil unless @input.tty?

        @prompt.confirm(question)
      end

      sig { override.params(text: String).void }
      def note(text)
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
        TerminalOwner.claim!("a prompt")
        nil
      end

      sig { override.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block)
        TerminalOwner.claim!("a frame")
        out.puts(title)
        block.call
      end

      # No spinner to animate, but the same rule: the plain tier is where
      # tests run, and a child spawned under a spin is a bug they catch.
      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def spin(name, &block)
        result = TerminalOwner.spinning { block.call }
        out.puts("#{CLI::UI::Glyph::CHECK.char} #{name}")
        result
      rescue StandardError
        out.puts("#{CLI::UI::Glyph::X.char} #{name}")
        raise
      end

      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def step(name, &block)
        TerminalOwner.claim!("a step")
        out.puts(name)
        result = block.call
        out.puts("#{CLI::UI::Glyph::CHECK.char} #{name}")
        result
      rescue StandardError
        out.puts("#{CLI::UI::Glyph::X.char} #{name}")
        raise
      end

      sig { override.params(question: String).returns(T.nilable(T::Boolean)) }
      def confirm(question)
        TerminalOwner.claim!("a prompt")
        nil
      end

      sig { override.params(text: String).void }
      def note(text)
        out.puts(CLI::UI.fmt(text, enable_color: false))
      end

      private

      sig { returns(T.any(IO, StringIO)) }
      def out = @out || $stdout
    end
  end
end
