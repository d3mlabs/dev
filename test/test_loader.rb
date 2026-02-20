# frozen_string_literal: true

# Entry point when running tests (-r test_loader). Load path, pry (before ASTTransform per rspock), then ASTTransform.
# test_helper is required by each test file and provides rspock + minitest.
DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "src")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "src"))

require "pry" # Must be before ASTTransform.install (per rspock) so binding.pry works and avoid require_relative errors
require "ast_transform"
ASTTransform.install
