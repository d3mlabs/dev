# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "dev"
  s.version     = File.read(File.expand_path("VERSION", __dir__)).strip
  s.summary     = "Find repo with dev.yml and run declared commands"
  s.homepage    = "https://github.com/d3mlabs/dev"
  s.license     = "MIT"
  s.authors     = ["d3mlabs"]

  # The codebase uses Ruby 3.1+ syntax (e.g. hash literal value omission).
  s.required_ruby_version = ">= 3.1.0"

  s.files = Dir["bin/*", "src/**/*", "lib/**/*", "data/**/*", "share/**/*", "VERSION", "LICENSE"]

  s.add_runtime_dependency "cli-ui"
  s.add_runtime_dependency "sorbet-runtime"
end
