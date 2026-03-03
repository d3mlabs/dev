#!/bin/sh
# Use PATH ruby (rbenv) if >= 2.7, fall back to Homebrew Ruby for bootstrapping.
# Skips macOS system Ruby 2.6 which is too old for sorbet-runtime.
if command -v ruby >/dev/null 2>&1; then
  if ruby -e 'exit(RUBY_VERSION >= "2.7" ? 0 : 1)' 2>/dev/null; then
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

require "open3"
require "cli/ui"
require "ensure_bundler"

CLI::UI::StdoutRouter.enable

class SorbetError < StandardError; end
class RbiOutOfDateError < StandardError; end

# CLI::UI.spinner returns false when the task fails (debrief prints exceptions
# but never re-raises), so we check each return value explicitly.
CLI::UI.frame("Type checking...") do
  unless CLI::UI.spinner("Install Bundler") { ensure_bundler!(DEV_ROOT) }
    exit 1
  end

  unless CLI::UI.spinner("Verifying gem RBIs are in sync...") do
    Dir.chdir(DEV_ROOT) do
      _, _, status = Open3.capture3("bundle", "exec", "tapioca", "gem", "--verify")

      unless status.success?
        raise RbiOutOfDateError,
          "RBI files are out of date. Run: dev rbi\nThen commit the updated sorbet/rbi/gems/ files."
      end
    end
  end
    exit 1
  end

  unless CLI::UI.spinner("Running type checking...") do
    _, err, status = Open3.capture3("bundle", "exec", "srb", "tc")
    raise SorbetError, "srb tc error: #{err}" unless status.success?
  end
    exit 1
  end
end

