# typed: strict
# frozen_string_literal: true

require "cli/ui"

module Dev
  module Cli
    # Global CLI::UI wrapper. This is a module (not a class) because CLI::UI
    # patches $stdout globally — there's no way to encapsulate that behind instances.
    # Three tiers: UiImpl (TTY), UiImpl with spinners:false (CI), NoUi (pipe/file).
    module Ui
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.params(title: String, block: T.proc.void).void }
      def frame(title, &block); end

      sig { abstract.params(title: String).void }
      def open_frame(title); end

      sig { abstract.params(title: String).void }
      def close_frame(title); end

      sig { abstract.params(str: String).returns(String) }
      def fmt(str); end

      sig { abstract.params(title: String, block: T.proc.void).void }
      def with_spinner(title, &block); end

      sig { abstract.params(label: String).void }
      def ok(label); end

      sig { abstract.params(label: String).void }
      def fail(label); end

      sig { abstract.params(message: String).void }
      def warn(message); end

      sig { abstract.params(message: String).void }
      def print_line(message); end

      sig { abstract.void }
      def done; end
    end

    class UiImpl
      extend T::Sig
      include Ui

      sig { returns(IO) }
      attr_reader :out

      sig { params(cli_ui: T.class_of(CLI::UI), out: IO, spinners: T::Boolean).void }
      def initialize(cli_ui:, out: $stdout, spinners: true)
        @cli_ui = T.let(cli_ui, T.class_of(CLI::UI))
        CLI::UI::StdoutRouter.enable
        @cli_ui.enable_color = true
        @out = T.let(out, IO)
        @spinners = T.let(spinners, T::Boolean)
      end

      sig { override.params(title: String, block: T.proc.void).void }
      def frame(title, &block)
        @cli_ui.frame(title, to: @out, &block)
      end

      sig { override.params(title: String).void }
      def open_frame(title)
        T.unsafe(CLI::UI::Frame).open(title, to: @out)
      end

      sig { override.params(title: String).void }
      def close_frame(title)
        T.unsafe(CLI::UI::Frame).close(title, to: @out)
      end

      sig { override.params(str: String).returns(String) }
      def fmt(str)
        @cli_ui.fmt(str)
      end

      sig { override.params(title: String, block: T.proc.void).void }
      def with_spinner(title, &block)
        if @spinners
          @cli_ui.spinner(title, to: @out, &block)
        else
          result = yield
          glyph = result ? ::CLI::UI::Glyph::CHECK : ::CLI::UI::Glyph::X
          @cli_ui.puts("#{glyph} #{title}", to: @out)
        end
      end

      sig { override.params(label: String).void }
      def ok(label)
        @cli_ui.puts("#{::CLI::UI::Glyph::CHECK} #{label}", to: @out)
      end

      sig { override.params(label: String).void }
      def fail(label)
        @cli_ui.puts("#{::CLI::UI::Glyph::X} #{label}", to: @out)
      end

      sig { override.params(message: String).void }
      def warn(message)
        @cli_ui.puts(fmt("{{yellow:#{message}}}"), to: @out)
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

      sig { override.params(title: String, block: T.proc.void).void }
      def frame(title, &block)
        $stdout.puts("--- #{title} ---")
        yield
      end

      sig { override.params(title: String).void }
      def open_frame(title)
        $stdout.puts("--- #{title} ---")
      end

      sig { override.params(title: String).void }
      def close_frame(title)
        # no-op for plain text
      end

      sig { override.params(str: String).returns(String) }
      def fmt(str)
        str
      end

      sig { override.params(title: String, block: T.proc.void).void }
      def with_spinner(title, &block)
        result = yield
        glyph = result ? "\u2713" : "\u2717"
        $stdout.puts("#{glyph} #{title}")
      end

      sig { override.params(label: String).void }
      def ok(label)
        $stdout.puts("\u2713 #{label}")
      end

      sig { override.params(label: String).void }
      def fail(label)
        $stdout.puts("\u2717 #{label}")
      end

      sig { override.params(message: String).void }
      def warn(message)
        $stdout.puts("WARNING: #{message}")
      end

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
