# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/keg_exec"
require "dev/deps/shadowenv_exec"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::KegExecTest < Minitest::Test
  # A keg whose `bin/bundle` reports what it was run with: its argv and
  # the one env key the test hands it.
  #
  # @param root [Pathname]
  # @return [Pathname] the keg
  def keg_with_reporting_bundle(root)
    keg = root / "Cellar/ruby@4.0.6/4.0.6"
    (keg / "bin").mkpath
    bundle = keg / "bin/bundle"
    bundle.write("#!/bin/sh\necho \"argv: $*\"\necho \"gemfile: ${BUNDLE_GEMFILE-unset}\"\n")
    bundle.chmod(0o755)
    keg
  end

  test "capture3 runs the program by its path under the keg's bin, with the caller's env layered in" do
    Given
    root = Pathname(Dir.mktmpdir("dev-keg-exec-"))
    keg = keg_with_reporting_bundle(root)

    When
    out, _err, status = Dev::Deps::KegExec.new(keg:).capture3("bundle", "install", env: { "BUNDLE_GEMFILE" => "/tree/Gemfile" })

    Then "the keg's own bundle ran, not PATH's"
    status.success?
    out == "argv: install\ngemfile: /tree/Gemfile\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a keg without the program fails as the spawn does — no fallback to PATH" do
    Given "a keg with an empty bin"
    root = Pathname(Dir.mktmpdir("dev-keg-exec-"))
    keg = root / "Cellar/ruby@4.0.6/4.0.6"
    (keg / "bin").mkpath

    When
    Dev::Deps::KegExec.new(keg:).capture3("ruby", "-v")

    Then
    raises Errno::ENOENT

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the seam is a ToolchainExec, as ShadowenvExec is" do
    Expect
    Dev::Deps::KegExec.include?(Dev::Deps::ToolchainExec)
    Dev::Deps::ShadowenvExec.include?(Dev::Deps::ToolchainExec)
  end
end
