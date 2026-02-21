#!/usr/bin/env ruby
# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")
require "ensure_bundler"

ensure_bundler!(DEV_ROOT)

exit_code = Dir.chdir(DEV_ROOT) do
  # Ensure gem RBIs are in sync with Gemfile.lock so drift is caught locally (not only on CI).
  unless system("bundle", "exec", "tapioca", "gem", "--verify", out: $stdout, err: $stderr)
    warn "\nRBI files are out of date. Run: dev rbi"
    warn "Then commit the updated sorbet/rbi/gems/ files."
    next 1
  end

  success = system("bundle", "exec", "srb", "tc", out: $stdout, err: $stderr)
  success ? 0 : 1
end

exit(exit_code)
