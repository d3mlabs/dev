# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/package"
require "dev/deps/package_id"
require "dev/deps/package_version"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PackageTest < Minitest::Test
  def id
    Dev::Deps::PackageId.new(integration: :bundler, name: "ffi")
  end

  test "encapsulates its identity and its available versions" do
    Given "a package with two versions in repository-reported order"
    v1 = Dev::Deps::PackageVersion.new(version: "1.17.0")
    v2 = Dev::Deps::PackageVersion.new(version: "1.17.4")
    package = Dev::Deps::Package.new(id: id, versions: [v2, v1])

    Expect "id and versions read back, order preserved"
    package.id == id
    package.versions == [v2, v1]
  end

  test "the version list is frozen at construction" do
    Given "a package built from a mutable array"
    package = Dev::Deps::Package.new(id: id, versions: [Dev::Deps::PackageVersion.new(version: "1.0.0")])

    Expect
    package.versions.frozen?
  end

  test "looks up a version by exact string" do
    Given "a package with a known version"
    wanted = Dev::Deps::PackageVersion.new(version: "1.17.4")
    package = Dev::Deps::Package.new(id: id, versions: [Dev::Deps::PackageVersion.new(version: "1.17.0"), wanted])

    When "looking it up exactly"
    found = package.version("1.17.4")

    Then
    found == wanted
  end

  test "exact lookup returns nil for an unknown version" do
    Given "a package without the requested version"
    package = Dev::Deps::Package.new(id: id, versions: [Dev::Deps::PackageVersion.new(version: "1.0.0")])

    Expect
    package.version("9.9.9").nil?
  end

  test "reports an empty universe" do
    Given "a package the backing service knows no versions for"
    package = Dev::Deps::Package.new(id: id, versions: [])

    Expect
    package.empty?
    !Dev::Deps::Package.new(id: id, versions: [Dev::Deps::PackageVersion.new(version: "1.0.0")]).empty?
  end
end
