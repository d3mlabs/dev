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

# Ensure commands like `bundle` and `gem` resolve to the same Ruby installation
ENV["PATH"] = "#{File.dirname(RbConfig.ruby)}:#{ENV['PATH']}"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")
require "ensure_bundler"

ensure_bundler!(DEV_ROOT)

Dir.chdir(DEV_ROOT) do
  success = system("bundle", "exec", "tapioca", "gem", out: $stdout, err: $stderr)
  exit(success ? 0 : 1)
end
