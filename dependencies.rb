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
  # The project Ruby: a brew pin from the d3mlabs tap (ruby@4.0.6), installed
  # by `dev deps install` and activated in the project shadowenv.
  # No gem declarations — the hand-written Gemfile stays bundler-managed.
  ruby "4.0.6"

  # The ai-flow dispatcher the reusable workflows run on this repo's jobs:
  # a 1.x release, resolved through the series head `v1` — the same ref the
  # caller workflows' `uses: …@v1` resolves. A major bump edits this line
  # and both callers.
  group :build do
    gh "d3mlabs/ai-flow", "^1", assets: "ai-flow-*.zip"
  end
end

BUNDLER_VERSION = ">= 2.1" unless defined?(BUNDLER_VERSION)
