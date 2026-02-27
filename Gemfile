# frozen_string_literal: true

source "https://rubygems.org"

# Pretty CLI (Frame, colors, spinners). Dev wraps commands in it; project scripts run in-process and inherit it.
gem "cli-ui"

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
gem "sorbet-runtime"
gem "tapioca", require: false, group: [:development, :test]

# RBS 4.0.0.dev.5 is the first version that supports Ruby 4.0
gem "rbs", "~> 4.0.0.dev.5"
