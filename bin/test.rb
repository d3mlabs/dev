#!/bin/sh
# Use PATH ruby (rbenv) if available, fall back to Homebrew Ruby for bootstrapping
if command -v ruby >/dev/null 2>&1; then
  exec ruby -x "$0" "$@"
fi
if command -v brew >/dev/null 2>&1; then
  brew_ruby="$(brew --prefix ruby 2>/dev/null)/bin/ruby"
  if [ -x "$brew_ruby" ]; then
    exec "$brew_ruby" -x "$0" "$@"
  fi
fi
echo "dev: no ruby found. Install rbenv and a Ruby version, or brew install ruby." >&2
exit 1

#!ruby
# frozen_string_literal: true

# Ensure commands like `bundle` and `gem` resolve to the same Ruby installation
ENV["PATH"] = "#{File.dirname(RbConfig.ruby)}:#{ENV['PATH']}"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")

require "open3"
require "cli/ui"
require "ensure_bundler"

CLI::UI::StdoutRouter.enable

class NoTestFilesError < StandardError; end
class TestError < StandardError; end

def main
  CLI::UI.frame("Running tests...") do
    CLI::UI.spinner("Install Bundler") do
      ensure_bundler!(DEV_ROOT)
    end

    test_files = []
    CLI::UI.spinner("Gathering test files...") do
      # test/ mirrors src/: test/dev/config_parser_test.rb for src/dev/config_parser.rb
      test_files = Dir[File.join(DEV_ROOT, "test", "**", "*_test.rb")]
      raise NoTestFilesError, "No test files found in test/" if test_files.empty?
    end

    CLI::UI.puts("")
    CLI::UI.frame("#{CLI::UI::Glyph::BUG} bundle exec rake test") do
      Open3.popen2e("bundle", "exec", "rake", "test") do |_stdin, stdout_err, wait_thr|
        stdout_err.each_line { |line| CLI::UI.puts(line.chomp) }
        unless wait_thr.value.success?
          e = TestError.new("Tests failed")
          e.set_backtrace([]) # no backtrace here, test output is already printed
          raise e
        end
      end
    end
  end
end

main
