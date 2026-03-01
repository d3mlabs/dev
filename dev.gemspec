# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "dev"
  s.version     = File.read(File.expand_path("VERSION", __dir__)).strip
  s.summary     = "Find repo with dev.yml and run declared commands"
  s.homepage    = "https://github.com/d3mlabs/dev"
  s.license     = "MIT"
  s.authors     = ["d3mlabs"]

  s.required_ruby_version = ">= 2.7.0"

  s.files = Dir["bin/*", "src/**/*", "lib/**/*", "VERSION", "LICENSE"]

  s.add_runtime_dependency "cli-ui"
  s.add_runtime_dependency "sorbet-runtime"
end
