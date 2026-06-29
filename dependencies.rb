# frozen_string_literal: true

# Prerequisites when running tests for managed repos (Ruby ecosystem).
# Used by bin/test.rb and dev up.
#
# This is a bootstrap constants file, not a Dev::Deps manifest: dev's own Ruby
# toolchain stays pinned in dev.yml (`ruby:`), which dev reads as the fallback
# when a repo has no `ruby` directive in a dependencies.rb manifest. The guard
# keeps re-loads idempotent, since dev loads this file to look for that directive.
BUNDLER_VERSION = ">= 2.1" unless defined?(BUNDLER_VERSION)
