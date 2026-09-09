# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package_id"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PackageIdTest < Minitest::Test
  test "identifies a package by integration and name" do
    Given "an id for a registry-backed package"
    id = Dev::Deps::PackageId.new(integration: :bundler, name: "ffi")

    Expect "the axes are readable and source defaults to nil"
    id.integration == :bundler
    id.name == "ffi"
    id.source.nil?
  end

  test "is value-equal, so it works as a resolved-set key" do
    Given "two ids built independently from the same coordinates"
    a = Dev::Deps::PackageId.new(integration: :bundler, name: "ffi")
    b = Dev::Deps::PackageId.new(integration: :bundler, name: "ffi")

    Expect "they are equal and collapse to one hash key"
    a == b
    { a => 1 }.key?(b)
  end

  test "the same name under different integrations is a different identity" do
    Given "'ffi' in the bundler universe and in the pip universe"
    gem_id = Dev::Deps::PackageId.new(integration: :bundler, name: "ffi")
    pip_id = Dev::Deps::PackageId.new(integration: :pip, name: "ffi")

    Expect "they do not collide"
    gem_id != pip_id
  end

  test "source-based ids carry their source coordinates" do
    Given "a git-backed cmake dependency"
    id = Dev::Deps::PackageId.new(integration: :cmake, name: "boost",
      source: "https://github.com/boostorg/boost.git")

    Expect "source participates in identity"
    id.source == "https://github.com/boostorg/boost.git"
    id != Dev::Deps::PackageId.new(integration: :cmake, name: "boost")
  end

  test "renders integration/name for registry ids" do
    Given "a registry-backed id"
    id = Dev::Deps::PackageId.new(integration: :brew, name: "cmake")

    Expect
    id.to_s == "brew/cmake"
  end

  test "renders the source alongside for source-based ids" do
    Given "a source-based id"
    id = Dev::Deps::PackageId.new(integration: :cmake, name: "boost",
      source: "https://github.com/boostorg/boost.git")

    Expect
    id.to_s == "cmake/boost (https://github.com/boostorg/boost.git)"
  end
end
