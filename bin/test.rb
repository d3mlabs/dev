#!/bin/sh
# Use PATH ruby (rbenv) if >= 3.1, fall back to Homebrew Ruby for bootstrapping.
# dev uses Ruby 3.1+ syntax (e.g. hash literal value omission).
if command -v ruby >/dev/null 2>&1; then
  if ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1") ? 0 : 1)' 2>/dev/null; then
    exec ruby -x "$0" "$@"
  fi
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

ENV["BUNDLE_GEMFILE"] ||= File.join(DEV_ROOT, "Gemfile")
require "bundler/setup"

require "fileutils"
require "open3"
require "cli/ui"
require "ensure_bundler"
require "rake_test_argv"

CLI::UI::StdoutRouter.enable

class NoTestFilesError < StandardError; end
class TestError < StandardError; end

# Stable artifact path, overwritten on every run, so failure triage can grep
# the file instead of re-running the suite. tmp/ is gitignored.
TEST_LOG_PATH = File.join(DEV_ROOT, "tmp", "test.log")

def main
  requested_files = ARGV
  CLI::UI.frame("Running tests...") do
    unless CLI::UI.spinner("Install Bundler") { ensure_bundler!(DEV_ROOT) }
      exit 1
    end

    unless CLI::UI.spinner("Gathering test files...") do
      if requested_files.empty?
        # test/ mirrors src/: test/dev/command_parser_test.rb for src/dev/command_parser.rb
        test_files = Dir[File.join(DEV_ROOT, "test", "**", "*_test.rb")]
        raise NoTestFilesError, "No test files found in test/" if test_files.empty?
      else
        # Fail fast on a typo'd path: rake would silently run zero tests.
        missing = requested_files.reject { |path| File.file?(File.expand_path(path, DEV_ROOT)) }
        raise NoTestFilesError, "No such test file(s): #{missing.join(", ")}" unless missing.empty?
      end
    end
      exit 1
    end

    rake_argv = rake_test_argv(requested_files)

    CLI::UI.puts("")
    CLI::UI.frame("#{CLI::UI::Glyph::BUG} #{rake_argv.join(" ")}") do
      suite_passed = false
      FileUtils.mkdir_p(File.dirname(TEST_LOG_PATH))
      File.open(TEST_LOG_PATH, "w") do |log|
        Open3.popen2e(*rake_argv) do |_stdin, stdout_err, wait_thr|
          stdout_err.each_line do |line|
            log.write(line)
            CLI::UI.puts(line.chomp)
          end
          suite_passed = wait_thr.value.success?
        end
      end
      CLI::UI.puts("Log: #{TEST_LOG_PATH}")
      unless suite_passed
        e = TestError.new("Tests failed (full output: #{TEST_LOG_PATH})")
        e.set_backtrace([]) # no backtrace here, test output is already printed
        raise e
      end
    end
  end
end

main
