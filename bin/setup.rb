#!/usr/bin/env ruby
# frozen_string_literal: true

# Setup dev environment: shadowenv Ruby, bundler from dependencies.rb, then bundle install.
# Run: dev up

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

require "ensure_bundler"
require "shadowenv_ruby"

puts "Setting up dev environment..."

# Shadowenv is expected to be installed with dev (formula should depend_on "shadowenv")
shadowenv_available = system("which", "shadowenv", out: File::NULL, err: File::NULL)
unless shadowenv_available
  puts "  ⚠️  shadowenv not found. Install dev via Homebrew (brew install d3mlabs/dev) to get shadowenv, or run: brew install shadowenv"
end
hook_just_added = false
if shadowenv_available
  result = setup_shadowenv_ruby!(DEV_ROOT) # Generates .shadowenv.d and auto-adds shell hook
  hook_just_added = result.is_a?(Array) && result[1] == :added
end

exit 1 unless ensure_bundler!(DEV_ROOT)

puts "  Installing dev repo gems..."
Dir.chdir(DEV_ROOT) do
  # Use shadowenv exec so bundle runs with the project Ruby when available
  install_cmd = shadowenv_available ? ["shadowenv", "exec", "--", "bundle", "install"] : ["bundle", "install"]
  unless system(*install_cmd)
    puts "  ⚠️  bundle install failed"
    exit 1
  end
end

puts "  Done."
if hook_just_added && $stdout.tty?
  puts "  Starting a shell with shadowenv active. Type 'exit' to return to your previous shell."
  exec(ENV["SHELL"] || "zsh", "-i")
end
