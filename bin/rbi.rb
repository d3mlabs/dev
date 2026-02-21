#!/usr/bin/env ruby
# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")
require "ensure_bundler"

ensure_bundler!(DEV_ROOT)

Dir.chdir(DEV_ROOT) do
  success = system("bundle", "exec", "tapioca", "gem", out: $stdout, err: $stderr)
  exit(success ? 0 : 1)
end
