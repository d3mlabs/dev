# typed: strict
# frozen_string_literal: true

require "cli/ui"

module Dev
  module Cli
    # Minimal UI interface for dev's own output (header + footer around commands).
    # Child scripts handle their own UI via CLI::UI with direct terminal access.
    # Two tiers: UiImpl (TTY/CI — colors and glyphs) and NoUi (pipe/file — plain text).
    module Ui
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.params(message: String).void }
      def print_line(message); end

      sig { abstract.void }
      def done; end
    end

    class UiImpl
      extend T::Sig
      include Ui

      sig { params(cli_ui: T.class_of(CLI::UI), out: IO).void }
      def initialize(cli_ui:, out: $stdout)
        @cli_ui = T.let(cli_ui, T.class_of(CLI::UI))
        @cli_ui.enable_color = true
        @out = T.let(out, IO)
      end

      sig { override.params(message: String).void }
      def print_line(message)
        @cli_ui.puts(message, to: @out)
      end

      sig { override.void }
      def done
        @cli_ui.puts("#{::CLI::UI::Glyph::CHECK} Done")
      end
    end

    class NoUi
      extend T::Sig
      include Ui

      sig { override.params(message: String).void }
      def print_line(message)
        $stdout.puts(message)
      end

      sig { override.void }
      def done
        $stdout.puts("Done")
      end
    end
  end
end
