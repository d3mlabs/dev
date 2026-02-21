# frozen_string_literal: true

source "https://rubygems.org"

# Pretty CLI (Frame, colors, spinners). Dev wraps commands in it; project scripts run in-process and inherit it.
gem "cli-ui"

# RSpock (from RubyGems) for test_helper and rspock-style tests
gem "rspock"

# Test (dev repo's own tests)
gem "minitest"
gem "rake"

# bin/console (pry + pry-byebug; pinned for Ruby 2.7 compatibility, per rspock)
gem "pry", "~> 0.13"
gem "pry-byebug", "~> 3.9"

# Sorbet: static + runtime type checking (see docs/sorbet.md).
# sorbet 0.5.11010 is the first version shipping sorbet-static as universal-darwin (no macOS version
# suffix), so it works on any macOS regardless of what Ruby reports. The sorbet gem only depends on
# sorbet-static (not sorbet-runtime), so we pin sorbet-runtime separately to 0.5.10461 — a version that
# does not enforce abstract methods at runtime (rbi 0.0.x declares RBI::Param as abstract!).
# Tapioca ~> 0.5.4 (before PR #865) depends on sorbet-static and sorbet-runtime separately.
# On Ruby 2.7, Bundler resolves rbi to 0.0.16 (the last version compatible with rspock's parser ~> 2.5).
# When rspock supports Ruby 3.2+, we can use latest sorbet + tapioca 0.17+ and drop all these pins.
gem "sorbet", "0.5.11010", group: :development
gem "sorbet-runtime", "0.5.10461"
gem "tapioca", "~> 0.5.4", require: false, group: [:development, :test]
