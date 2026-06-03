# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RepositoryTest < Minitest::Test
  test "base class fetch raises NotImplementedError" do
    Given "a base Repository instance"
    repo = Dev::Deps::Repository.new

    When
    error = begin
      repo.fetch("boost>=1.0")
      nil
    rescue NotImplementedError => e
      e
    end

    Then
    !error.nil?
    error.is_a?(NotImplementedError)
  end
end
