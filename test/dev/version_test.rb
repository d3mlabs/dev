# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/version"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::VersionTest < Minitest::Test
  include SorbetHelper

  test "current reads the VERSION file at dev's root, trimmed" do
    Given "a root carrying a VERSION file"
    root = Dir.mktmpdir("dev-version-")
    File.write(File.join(root, "VERSION"), "0.2.98\n")

    Expect "the version string alone"
    Dev::Version.current(root:) == "0.2.98"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "current raises UnknownVersionError when the root has no VERSION file" do
    Given "an empty root"
    root = Dir.mktmpdir("dev-version-missing-")

    When "reading the version"
    Dev::Version.current(root:)

    Then "the error names the root and the remediation"
    error = raises Dev::Version::UnknownVersionError
    error.message.include?(root)
    error.message.include?("brew upgrade")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the default root is this checkout, which carries VERSION" do
    Expect "a dotted version"
    Dev::Version.current.match?(/\A\d+\.\d+\.\d+\z/)
  end
end
