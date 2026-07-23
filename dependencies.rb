# frozen_string_literal: true

# dev's own dependency manifest. Loaded in two ways:
# - by dev itself (before every command) to read the project toolchain;
# - by bin/setup.rb and bin/test.rb BEFORE the bundle exists, for the
#   bootstrap constants below. The dev/deps require chain is stdlib-only,
#   so this file must stay loadable pre-bundle (both callers put lib/ on
#   the load path first). The guard keeps re-loads idempotent.
require "dev/deps"

Dev::Deps.define do
  # The project Ruby toolchain; dev provisions it (rbenv + shadowenv).
  # No gem declarations — the hand-written Gemfile stays bundler-managed.
  ruby "4.0.6"
end

BUNDLER_VERSION = ">= 2.1" unless defined?(BUNDLER_VERSION)
