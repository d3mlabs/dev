# frozen_string_literal: true

DEV_ROOT = File.expand_path("..", __dir__) unless defined?(DEV_ROOT)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "src")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "src"))

require "sorbet-runtime"
require "rspock" unless defined?(RSpock)

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
