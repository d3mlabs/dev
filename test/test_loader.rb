# frozen_string_literal: true

# Entry point when running tests (-r test_loader). Follows RSpock convention: load path, rspock, pry, then ASTTransform.
# test_helper is required by each test file and provides minitest.
DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "src")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "src"))

require "rspock"

# Pry
# NOTE: Must be loaded before ASTTransform.install, otherwise we get a bunch of require_relative errors
require 'pry'

ASTTransform.install
