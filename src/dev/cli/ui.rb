# typed: strict
# frozen_string_literal: true

require "cli/ui"

module Dev
  module Cli
    # Global CLI::UI wrapper. This is a module (not a class) because CLI::UI
    # patches $stdout globally — there's no way to encapsulate that behind instances.
    # Degrades to plain output when not on a TTY.
    module Ui
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.params(title: String, block: T.proc.void).void }
      def frame(title, &block); end

      sig { abstract.params(str: String).returns(String) }
      def fmt(str); end

      sig { abstract.params(title: String, block: T.proc.void).void }
      def with_spinner(title, &block); end

      sig { abstract.params(message: String).void }
      def puts(message); end
    end

    class UiImpl
      extend T::Sig
      include Ui

      sig { returns(IO) }
      attr_reader :out

      sig { params(cli_ui: T.class_of(CLI::UI), out: IO).void }
      def initialize(cli_ui:, out: $stdout)
        @cli_ui = T.let(cli_ui, T.class_of(CLI::UI))
        @cli_ui.enable
        @cli_ui.enable_color = true
        @out = T.let(out, IO)
      end

      sig { override.params(title: String, block: T.proc.void).void }
      def frame(title, &block)
        @cli_ui.frame(title, to: @out, &block)
      end

      sig { override.params(str: String).returns(String) }
      def fmt(str)
        @cli_ui.fmt(str, to: @out)
      end

      sig { override.params(title: String, block: T.proc.void).void }
      def with_spinner(title, &block)
        @cli_ui.spinner(title, to: @out, &block)
      end

      sig { override.params(message: String).void }
      def puts(message)
        @cli_ui.puts(message, to: @out)
      end

      sig { void }
      def done
        @cli_ui.puts("#{::CLI::UI::Glyph::CHECK.to_s} Done")
      end
    end

    class NoUi
      extend T::Sig
      include Ui

      # def initialize(out: $stdout); end

      sig { override.params(title: String, block: T.proc.void).void }
      def frame(title, &block)
        yield
      end
      
      sig { override.params(str: String).returns(String) }
      def fmt(str)
        str
      end
    end
  end
end
