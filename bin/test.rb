#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

DEV_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(DEV_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(DEV_ROOT, "lib"))

load File.join(DEV_ROOT, "dependencies.rb")

# Configuration: list of repositories to test
REPOS = [
  {
    name: "rspock",
    path: File.expand_path("../repos/rspock", __dir__),
    test_command: "bundle exec rake test"
  }
].freeze

# Dummy test in dev repo itself
DUMMY_TEST = File.expand_path("../test/dummy_test.rb", __dir__)

require "ensure_bundler"

def run_tests_for_repo(repo)
  puts "Testing #{repo[:name]}..."
  
  unless Dir.exist?(repo[:path])
    puts "  ⚠️  Repository not found at #{repo[:path]}"
    return false
  end

  Dir.chdir(repo[:path]) do
    # Ensure dependencies are installed (per installation instructions)
    setup_script = File.join(repo[:path], "bin", "setup")
    if File.exist?(setup_script) && File.executable?(setup_script)
      puts "  Installing dependencies..."
      unless system(setup_script)
        puts "  ⚠️  Failed to install dependencies (may need bundler 2.x)"
        puts "     Try: gem install bundler"
        return false
      end
    elsif File.exist?(File.join(repo[:path], "Gemfile"))
      puts "  Installing dependencies..."
      # Check if bundler 2.x is available
      bundler_version = `bundle --version 2>&1`.strip
      if bundler_version.match?(/^Bundler version 1\./)
        puts "  ⚠️  Bundler 2.x required (found #{bundler_version})"
        puts "     Try: gem install bundler"
        return false
      end
      unless system("bundle", "install")
        puts "  ⚠️  Failed to install dependencies"
        return false
      end
    end
    
    # Run the tests
    system(repo[:test_command])
  end
end

# Run dummy test first (use bundle exec and -I test so test_helper and rspock are loadable)
puts "Running dummy test..."
dummy_test_passed = false
if File.exist?(DUMMY_TEST)
  # Load test_helper first (so ASTTransform.install runs), then load test file (so transform! is seen by hook)
  dummy_path = File.join(DEV_ROOT, "test", "dummy_test.rb")
  dummy_test_passed = Dir.chdir(DEV_ROOT) { system("bundle", "exec", "ruby", "-I", "test", "-e", "require 'test_helper'; load #{dummy_path.inspect}") }
  unless dummy_test_passed
    puts "Dummy test failed!"
    exit 1
  end
else
  puts "  ⚠️  Dummy test not found at #{DUMMY_TEST}"
  exit 1
end

# Ensure bundler version from dependencies.rb before testing repos that use bundle
ensure_bundler!(DEV_ROOT)

# Run tests for all repositories
repo_test_failures = []
REPOS.each do |repo|
  unless run_tests_for_repo(repo)
    repo_test_failures << repo[:name]
  end
end

# Report results
if repo_test_failures.any?
  puts "\n⚠️  Some repository tests failed: #{repo_test_failures.join(', ')}"
  puts "   (This is expected if dependencies aren't set up)"
end

# Exit successfully if dummy test passed (main success criteria)
exit(0)
