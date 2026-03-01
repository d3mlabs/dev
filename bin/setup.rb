#!/bin/sh
# Prefer Homebrew Ruby if available, fall back to system Ruby
if command -v brew >/dev/null 2>&1; then
  brew_ruby="$(brew --prefix ruby 2>/dev/null)/bin/ruby"
  if [ -x "$brew_ruby" ]; then
    exec "$brew_ruby" -x "$0" "$@"
  fi
fi
exec ruby -x "$0" "$@"

#!ruby
# frozen_string_literal: true

# Setup dev environment: ensure bundler from dependencies.rb, then bundle install.
# Shadowenv Ruby provisioning is handled by the dev CLI core before this script runs.
# Run: dev up

# Ensure commands like `bundle` and `gem` resolve to the same Ruby installation
ENV["PATH"] = "#{File.dirname(RbConfig.ruby)}:#{ENV['PATH']}"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

require "ensure_bundler"

puts "Setting up dev environment..."

exit 1 unless ensure_bundler!(DEV_ROOT)

puts "  Installing dev repo gems..."
Dir.chdir(DEV_ROOT) do
  unless system("bundle", "install")
    $stderr.puts "  bundle install failed"
    exit 1
  end
end

puts "  Done."
