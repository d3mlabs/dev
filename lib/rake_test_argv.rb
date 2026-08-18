# frozen_string_literal: true

# Builds the `bundle exec rake test` argv for bin/test.rb (dev test).
#
# Rake's TestTask (rake 13.3) reads ENV["TEST"] as a single glob pattern,
# so multiple requested files are joined into one brace glob ({a,b})
# rather than passed as separate values.
#
# @param test_files [Array<String>] test file paths relative to the repo
#   root; empty means the full suite
# @return [Array<String>] argv for the child rake process
def rake_test_argv(test_files)
  argv = ["bundle", "exec", "rake", "test"]
  return argv if test_files.empty?

  pattern = test_files.size == 1 ? test_files.fetch(0) : "{#{test_files.join(",")}}"
  argv + ["TEST=#{pattern}"]
end
