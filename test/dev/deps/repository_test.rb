# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/repository"
require "dev/deps/pin"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RepositoryTest < Minitest::Test
  test "base class resolve raises NotImplementedError" do
    Given
    repo = Dev::Deps::Repository.new

    When
    error = begin
      repo.resolve("boost", ">= 1.0", cache: nil)
      nil
    rescue NotImplementedError => e
      e
    end

    Then
    !error.nil?
    error.is_a?(NotImplementedError)
  end

  test "base class dependencies returns empty array by default" do
    Given
    repo = Dev::Deps::Repository.new
    pin = Dev::Deps::Pin.new(
      name: "boost", integration: :cmake, group: :app,
      version: "1.90.0", hash: "SHA256=abc", metadata: {},
    )

    When
    deps = repo.dependencies(pin)

    Then
    deps == []
  end
end
