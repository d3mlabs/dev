# typed: strict
# frozen_string_literal: true

require "cli/ui"
require "stringio"

module Dev
  module Cli
    # Minimal UI interface for dev's own output. Dev prints a colored header
    # (command name) before exec-ing into the child process. The child handles
    # all its own UI (CLI::UI frames, spinners, prompts).
    #
    # Two tiers: UiImpl (TTY/CI — colored header) and NoUi (pipe/file — plain text).
    module Ui
      extend T::Sig
      extend T::Helpers

      interface!

      # What the crossing line says before the environment's name.
      CROSSING_PREFIX = "→ in "

      sig { abstract.params(command: String).void }
      def print_header(command); end

      # The one line about where a command runs, printed only at a
      # crossing — when the command's body enters a container of its
      # image (dev#409). Dim: a note under the header, not a header.
      #
      # @param environment [String] the image's name
      sig { abstract.params(environment: String).void }
      def print_crossing(environment); end

      # Ask for a secret at the terminal, input hidden. nil when there is
      # no terminal to ask at (a pipe, CI): the caller falls back to its
      # headless path — it never blocks on a prompt nobody will see.
      #
      # @param question [String]
      # @return [String, nil] the answer ("" when the user just pressed Enter)
      sig { abstract.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question); end
    end

    class UiImpl
      extend T::Sig
      include Ui

      # @param cli_ui [Class] CLI::UI
      # @param prompt [Class] CLI::UI::Prompt (injectable for tests)
      # @param input [IO, StringIO] what the prompt would read: a terminal, or not
      sig { params(cli_ui: T.class_of(CLI::UI), prompt: T.class_of(CLI::UI::Prompt), input: T.any(IO, StringIO)).void }
      def initialize(cli_ui:, prompt: CLI::UI::Prompt, input: $stdin)
        @cli_ui = cli_ui
        @prompt = prompt
        @input = input
        @cli_ui.enable_color = true
      end

      sig { override.params(command: String).void }
      def print_header(command)
        @cli_ui.puts(@cli_ui.fmt("{{bold:#{command}}}"))
      end

      sig { override.params(environment: String).void }
      def print_crossing(environment)
        @cli_ui.puts(@cli_ui.fmt("{{gray:#{CROSSING_PREFIX}#{environment}}}"))
      end

      sig { override.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question)
        return nil unless @input.tty?

        @prompt.ask_password(question)
      end
    end

    class NoUi
      extend T::Sig
      include Ui

      sig { override.params(command: String).void }
      def print_header(command)
        $stdout.puts(command)
      end

      sig { override.params(environment: String).void }
      def print_crossing(environment)
        $stdout.puts("#{CROSSING_PREFIX}#{environment}")
      end

      sig { override.params(question: String).returns(T.nilable(String)) }
      def ask_secret(question)
        nil
      end
    end
  end
end
