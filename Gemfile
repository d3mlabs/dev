# frozen_string_literal: true

source "https://rubygems.org"

# Runtime deps (cli-ui, sorbet-runtime) come from the gemspec.
gemspec

# RSpock (from RubyGems) for test_helper and rspock-style tests
gem "rspock", "~> 2.3"

# Test (dev repo's own tests)
gem "minitest"
gem "rake"

# bin/console
gem "pry", "~> 0.14"
gem "pry-byebug", "~> 3.11"

# Sorbet: static + runtime type checking
gem "sorbet", group: :development
gem "tapioca", require: false, group: [:development, :test]

# RBS 4.0.0.dev.5 is the first version that supports Ruby 4.0
gem "rbs", "~> 4.0.0.dev.5"
# We need this to be ported to the RBS 4.0 branch before we can remove this dependency:
# https://github.com/ruby/rbs/pull/2601
# Until rbs supports Ruby 4.0 with tsort extracted to bundled gems
# gem "tsort"
