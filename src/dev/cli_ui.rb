# frozen_string_literal: true

module Dev
  # Enables CLI::UI (Frame, colors) when stdout is a TTY; no-op otherwise or if cli-ui is not installed.
  class CliUi
    def self.enable
      new.enable
    end

    def enable
      return unless $stdout.tty?
      require "cli/ui"
      CLI::UI::StdoutRouter.enable
      CLI::UI.enable_color = true if CLI::UI.respond_to?(:enable_color=)
    rescue LoadError
      # cli-ui not installed; run without pretty output
    end
  end
end
