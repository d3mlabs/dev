# typed: strict
# frozen_string_literal: true

require "cli/ui"
require "stringio"
require "dev/terminal_owner"
require "dev/ui"

module Dev
  module Cli
    # The cli-ui tier of Dev::Ui — frames, spinners, prompts at a terminal
    # or under CI / CLICOLOR_FORCE; bin/dev picks it over NoUi. The
    # vocabulary and its contract are documented on Dev::Ui.
    class UiImpl
      extend T::Sig
      include Ui

      # cli-ui's spinner answered false without the block having raised:
      # the block never ran (its Capture refused — the router was off, or
      # cli-ui changed its mind). Never nil as if it had run.
      class SpinnerRefusedError < RuntimeError; end

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
      # `enabled?` reads, so a second `enable` refuses), and
      # nothing needs it off — a child's fd 1 is never the Ruby-level
      # `$stdout`, and with no frame open the router prefixes nothing.
      sig { override.type_parameters(:T).params(title: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def frame(title, &block)
        TerminalOwner.claim!("a frame")
        @router.enable
        @frame.open(title, timing: true, &block)
      end

      # The router first: cli-ui runs the block inside a StdoutRouter
      # Capture, which refuses with the router off — silently, the block
      # never running, the spinner answering false (a verb whose
      # first word is a spin, with no frame before it). The spinner
      # swallows the block's raise and answers false (auto_debrief off: no
      # backtrace dump — the verb reports the failure in its own words);
      # the raise is kept and re-raised. False with no raise kept is the
      # block never having run, and says so.
      sig { override.type_parameters(:T).params(name: String, block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def spin(name, &block)
        @router.enable
        result = T.let(nil, T.nilable(T.type_parameter(:T)))
        failure = T.let(nil, T.nilable(StandardError))
        ran = TerminalOwner.spinning do
          @spinner.spin(name, auto_debrief: false) do
            result = block.call
          rescue StandardError => e
            failure = e
            raise
          end
        end
        raise failure if failure
        raise SpinnerRefusedError, "the spinner never ran its block: #{name}" unless ran

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

      sig { override.params(question: String, default: T::Boolean).returns(T.nilable(T::Boolean)) }
      def confirm(question, default: false)
        TerminalOwner.claim!("a prompt")
        return nil unless @input.tty?

        @prompt.confirm(question, default: default)
      end

      sig { override.params(text: String).void }
      def note(text)
        @cli_ui.puts(@cli_ui.fmt(text))
      end
    end
  end
end
