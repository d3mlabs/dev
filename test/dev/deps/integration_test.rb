# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/integration"
require "dev/deps/repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::IntegrationTest < Minitest::Test
  test "base class install_all raises NotImplementedError" do
    Given "an Integration with injected dependencies"
    repo = Dev::Deps::Repository.new
    integration = Dev::Deps::Integration.new(repository: repo, cache: nil)

    When "calling install_all"
    integration.install_all([])

    Then
    raises NotImplementedError
  end
end
