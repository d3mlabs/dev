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
    integration = Dev::Deps::Integration.new(repository: repo, store: nil)

    When "calling install_all"
    integration.install_all([])

    Then
    raises NotImplementedError
  end

  test "base class tree_key raises NotImplementedError: an integration without a tree places nothing" do
    Given "a locked dep and the base Integration"
    dep = Dev::Deps::Dependency.new(
      name: "x", integration: :none, group: :app, version: "1", hash: nil, metadata: {},
    )

    When "asking the base class where its tree is"
    error = assert_raises(NotImplementedError) { Dev::Deps::Integration.tree_key(dep) }

    Then "it says the integration installs no tree"
    error.message.include?("installs no tree")
  end
end
