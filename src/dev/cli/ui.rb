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

      sig { params(title: String, block: T.proc.void).void }
      def self.frame(title, &block)
        if $stdout.tty?
          ensure_enabled!
          CLI::UI::Frame.open(title, &block)
        else
          yield
        end
      end

      sig { params(str: String).returns(String) }
      def self.fmt(str)
        if $stdout.tty?
          ensure_enabled!
          CLI::UI.fmt(str)
        else
          str
        end
      end

      # Eagerly enable CLI::UI. Use this when callers need CLI::UI
      # directly (e.g. CommandRunner) rather than going through Cli::Ui.frame/fmt.
      sig { void }
      def self.activate!
        ensure_enabled! if $stdout.tty?
      end

      sig { void }
      def self.ensure_enabled!
        @enabled = T.let(@enabled, T.nilable(T::Boolean))
        return if @enabled
        CLI::UI::StdoutRouter.enable
        CLI::UI.enable_color = true if CLI::UI.respond_to?(:enable_color=)
        @enabled = true
      end

      private_class_method :ensure_enabled!
    end
  end
end
