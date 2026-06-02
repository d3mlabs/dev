# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/integration"
require "dev/deps/repository"
require "dev/deps/pin"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::IntegrationTest < Minitest::Test
  test "base class requires repository and cache at construction" do
    Given
    repo = Dev::Deps::Repository.new

    When
    integration = Dev::Deps::Integration.new(repository: repo, cache: nil)

    Then
    integration.repository == repo
  end

  test "base class install_all raises NotImplementedError" do
    Given
    repo = Dev::Deps::Repository.new
    integration = Dev::Deps::Integration.new(repository: repo, cache: nil)
    dir = Dir.mktmpdir("dev-integration-test-")

    When
    error = begin
      integration.install_all([], root: dir)
      nil
    rescue NotImplementedError => e
      e
    end

    Then
    !error.nil?
    error.is_a?(NotImplementedError)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "integration is immutable after construction" do
    Given
    repo = Dev::Deps::Repository.new
    integration = Dev::Deps::Integration.new(repository: repo, cache: nil)

    Expect
    integration.frozen?
  end
end
