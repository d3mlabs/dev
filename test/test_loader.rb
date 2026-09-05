# typed: false
# frozen_string_literal: true

# Entry point when running tests (-r test_loader). Follows RSpock convention: load path, rspock, pry, then ASTTransform.
# test_helper is required by each test file and provides minitest.

# SimpleCov must start before any application code loads so every file is tracked.
require "simplecov"
require "simplecov-cobertura"

# HTML for local browsing; cobertura for the codecov upload (its parser
# can't process SimpleCov JSON containing skipped/ignored lines —
# codecov/engineering-team#3592).
SimpleCov.start do
  skip("/test/")
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter,
  ])
end

# simplecov/sorbet skips type-level Sorbet constructs (sig blocks,
# T.type_alias, T.absurd) so they never read as coverage misses.
require "simplecov/sorbet"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "src")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "src"))
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

require "rspock"

# Pry
# NOTE: Must be loaded before ASTTransform.install, otherwise we get a bunch of require_relative errors
require 'pry'

ASTTransform.install
