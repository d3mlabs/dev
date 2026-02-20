# frozen_string_literal: true

# Prerequisites when running tests for managed repos (Ruby ecosystem).
# Used by bin/test.rb and dev up. Shadowenv uses this to generate .shadowenv.d/510_ruby.lisp.

BUNDLER_VERSION = "~> 2.1"

# Ruby version for this project (used by shadowenv generator and .ruby-version).
RUBY_VERSION_REQUESTED = "2.7.6"
