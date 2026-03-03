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

# Setup dev environment: ensure bundler from dependencies.rb, then bundle install.
# Shadowenv Ruby provisioning is handled by the dev CLI core before this script runs.
# Run: dev up

# Ensure commands like `bundle` and `gem` resolve to the same Ruby installation
ENV["PATH"] = "#{File.dirname(RbConfig.ruby)}:#{ENV['PATH']}"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

ENV["BUNDLE_GEMFILE"] ||= File.join(DEV_ROOT, "Gemfile")
require "bundler/setup"

require "open3"
require "cli/ui"
require "ensure_bundler"

CLI::UI::StdoutRouter.enable

class BundleInstallError < StandardError; end

CLI::UI.frame("Setting up dev environment...") do
  CLI::UI.spinner("Installing bundler...") do
    ensure_bundler!(DEV_ROOT)
  end

  CLI::UI.spinner("💎 bundle install") do
    out, err, status = Open3.capture3("bundle", "install")
    raise BundleInstallError, "bundle install error: #{err}" unless status.success?
  end
end
