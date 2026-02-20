#!/usr/bin/env ruby
# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")
require "ensure_bundler"

# Run this repo's tests only
ensure_bundler!(DEV_ROOT)

dummy_path = File.join(DEV_ROOT, "test", "dummy_test.rb")
unless File.exist?(dummy_path)
  puts "  ⚠️  Test not found at #{dummy_path}"
  exit 1
end

puts "Running tests..."
success = Dir.chdir(DEV_ROOT) do
  system("bundle", "exec", "ruby", "-I", "test", "-e", "require 'test_helper'; load #{dummy_path.inspect}")
end

exit(success ? 0 : 1)
