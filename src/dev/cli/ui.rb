# typed: strict
# frozen_string_literal: true

require "cli/ui"

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

      sig { abstract.params(command: String).void }
      def print_header(command); end
    end

    class UiImpl
      extend T::Sig
      include Ui

      sig { params(cli_ui: T.class_of(CLI::UI)).void }
      def initialize(cli_ui:)
        @cli_ui = T.let(cli_ui, T.class_of(CLI::UI))
        @cli_ui.enable_color = true
      end

      sig { override.params(command: String).void }
      def print_header(command)
        @cli_ui.puts(@cli_ui.fmt("{{bold:#{command}}}"))
      end
    end

    class NoUi
      extend T::Sig
      include Ui

      sig { override.params(command: String).void }
      def print_header(command)
        $stdout.puts(command)
      end
    end
  end
end
