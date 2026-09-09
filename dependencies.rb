# typed: false
# frozen_string_literal: true

# dev's own dependency manifest. Loaded in two ways:
# - by dev itself (before every command) to read the project toolchain;
# - by EnsureBundler (for the bin/ scripts), for the bootstrap constants
#   below. Every caller activates gems first (bundler/setup or plain
#   RubyGems), so the dev/deps require chain is free to use sorbet-runtime.
#   The guard keeps re-loads idempotent.
require "dev/deps"

Dev::Deps.define do
  # The project Ruby toolchain; dev provisions it (rbenv + shadowenv).
  # No gem declarations — the hand-written Gemfile stays bundler-managed.
  ruby "4.0.6"
end

BUNDLER_VERSION = ">= 2.1" unless defined?(BUNDLER_VERSION)
