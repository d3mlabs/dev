# frozen_string_literal: true

require "rake/testtask"

# Like rspock and cli-ui: test_loader runs first (-r) so ASTTransform.install and load path are set before any test.
# test/ mirrors src/: test/dev/*_test.rb for src/dev/*.rb
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << File.expand_path("src", __dir__)
  t.ruby_opts << "-r #{File.expand_path('test/test_loader.rb', __dir__)}"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
