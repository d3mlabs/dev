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

class SorbetError < StandardError; end

CLI::UI.frame("Type checking...") do
  CLI::UI.spinner("Install Bundler") do
    ensure_bundler!(DEV_ROOT)
  end

  CLI::UI.spinner("Verifying gem RBIs are in sync...") do
    Dir.chdir(DEV_ROOT) do
      out, err, status = Open3.capture3("bundle", "exec", "tapioca", "gem", "--verify")
      
      unless status.success?
        warn "\nRBI files are out of date. Run: dev rbi"
        warn "Then commit the updated sorbet/rbi/gems/ files."
        next 1
      end
    end
  end

  CLI::UI.spinner("Running type checking...") do
    out, err, status = Open3.capture3("bundle", "exec", "srb", "tc")
    raise SorbetError, "srb tc error: #{err}" unless status.success?
  end
end

