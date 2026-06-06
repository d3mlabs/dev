# frozen_string_literal: true

module Dev
  module Deps
    # Shared CLI presentation helpers for dependency operations.
    #
    # Wraps CLI::UI (optional gem) with plain-text fallbacks. Any layer
    # that needs progress/status output (integrations, fetcher, orchestrator)
    # should call through this module rather than coupling to CLI::UI directly.
    module CliUI
      def self.available?
        return @available if defined?(@available)

        @available = begin
          require "cli/ui"
          true
        rescue LoadError
          false
        end
      end

      # Print a success status line.
      #
      # @param name [String] label to display
      def self.step_ok(name)
        if available?
          CLI::UI.puts("#{CLI::UI::Glyph::CHECK} #{name}")
        else
          puts "  ok: #{name}"
        end
      end

      # Print a failure status line.
      #
      # @param name [String] label to display
      def self.step_fail(name)
        if available?
          CLI::UI.puts("#{CLI::UI::Glyph::X} #{name}")
        else
          puts "  FAIL: #{name}"
        end
      end

      # Run a block with a spinner (or plain-text fallback).
      #
      # @param title [String] spinner label
      # @yield block to execute during spinner
      def self.with_spinner(title, &block)
        if available?
          CLI::UI::Spinner.spin(title, &block)
        else
          puts "  #{title}..."
          block.call
        end
      end

      # Sanitize a string to valid UTF-8.
      #
      # @param str [String, nil] input string
      # @return [String, nil] UTF-8 safe string
      def self.sanitize_utf8(str)
        return str if str.nil? || (str.encoding == Encoding::UTF_8 && str.valid_encoding?)

        str.dup.force_encoding(Encoding::UTF_8).encode(
          Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?",
        )
      end
    end
  end
end
