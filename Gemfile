# frozen_string_literal: true

source "https://rubygems.org"

# Runtime deps (cli-ui, sorbet-runtime) come from the gemspec.
gemspec

# RSpock (from RubyGems) for test_helper and rspock-style tests; 3.0 also
# ships the rspock agent skill the learnings index points at.
gem "rspock", "~> 3.0"

# Test (dev repo's own tests)
gem "minitest"
gem "minitest-reporters"
gem "rake"
gem "simplecov", "~> 0.22"
# Codecov can't process SimpleCov's JSON once a `# :nocov:` line appears
# (the "ignored" value breaks its parser — codecov/engineering-team#3592),
# so CI uploads the cobertura report instead.
gem "simplecov-cobertura", "~> 3.0"

# bin/console
gem "pry", "~> 0.14"
gem "pry-byebug", "~> 3.11"

# Style
gem "rubocop-shopify", "~> 3.0", require: false
gem "rubocop-sorbet", "~> 0.10", require: false

# Sorbet: static + runtime type checking
gem "sorbet", group: :development
gem "tapioca", require: false, group: [:development, :test]

# RBS 4.0.0.dev.5 is the first version that supports Ruby 4.0
gem "rbs", "~> 4.0.0.dev.5"
# We need this to be ported to the RBS 4.0 branch before we can remove this dependency:
# https://github.com/ruby/rbs/pull/2601
# Until rbs supports Ruby 4.0 with tsort extracted to bundled gems
# gem "tsort"
