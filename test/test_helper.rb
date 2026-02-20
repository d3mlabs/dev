# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "src")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "src"))

# So binding.pry breakpoints work when running dev test.
require "pry"

# Per rspock README: install the ASTTransform hook at the very beginning
# https://github.com/rspockframework/rspock#installation
require "ast_transform"
ASTTransform.install

# RSpock; load before any file that uses transform!(RSpock::AST::Transformation).
require "rspock" unless defined?(RSpock)
require "rspock/backtrace_filter"
require "rspock/declarative"
require "rspock/ast/transformation"

# Minitest (load before mocha so MiniTest constant is available)
begin
  require "rubygems"
  gem "minitest"
rescue Gem::LoadError
  # do nothing
end

require "minitest"
MiniTest = Minitest # mocha/minitest expects the old name
require "minitest/spec"
require "minitest/mock"
require "mocha/minitest"
require "minitest/hell" if ENV["MT_HELL"]

# Minitest Reporters (optional; rspock uses RakeRerunReporter)
begin
  require "minitest/reporters"
  require "minitest/reporters/rake_rerun_reporter"
  Minitest::Reporters.use!([Minitest::Reporters::RakeRerunReporter.new])
rescue LoadError
  # minitest-reporters not installed
end

Minitest.autorun
