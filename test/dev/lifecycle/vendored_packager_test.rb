# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "support/recording_toolchain_exec"
require "support/tool_tree_fixtures"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::VendoredPackagerTest < Minitest::Test
  include LifecycleFixtures
  include ToolTreeFixtures

  # A Packager that records what it was handed and answers a fixed asset.
  class RecordingPackager
    include Dev::Lifecycle::Packager

    attr_reader :packaged

    def initialize
      @packaged = []
    end

    def package(build, stage, archive, acceptance: Dev::Lifecycle::Acceptance.unconditional)
      @packaged << [build, stage, archive, acceptance]
      Dev::Lifecycle::PackedArchive.new(archive: Pathname("#{archive}.zip"))
    end

    def to_s
      "archive"
    end
  end

  # A self-contained tree as a Ruby project's builder lays it, as the
  # stage: manifest, lock, Gemfile and an executable.
  #
  # @param root [Pathname]
  # @return [Pathname] the stage
  def tool_stage(root)
    tool_tree(root / "stage")
  end

  test "vendoring bundles the stage's gems frozen into its own vendor/bundle under the project's toolchain, then hands it to the packager" do
    Given
    root = Pathname(Dir.mktmpdir("vendored-packager-"))
    stage = tool_stage(root)
    exec = RecordingToolchainExec.new(effect: ->(_argv, env) { Pathname(env.fetch("BUNDLE_PATH")).join("ruby/4.0.0").mkpath })
    archiver = RecordingPackager.new
    packager = Dev::Lifecycle::VendoredPackager.new(packager: archiver, exec: exec)
    released = build("rspock")
    acceptance = Dev::Lifecycle::Acceptance.unconditional

    When
    packed = packager.package(released, stage, root / "store/ai-flow", acceptance:)

    Then "the vendored tree, and the destinations to show it to, both reach the wrapped packager"
    exec.calls == [[
      ["bundle", "install"],
      {
        "BUNDLE_GEMFILE" => "#{stage}/Gemfile",
        "BUNDLE_PATH" => "#{stage}/vendor/bundle",
        "BUNDLE_FROZEN" => "true",
        "BUNDLE_WITHOUT" => "development:test",
        "BUNDLE_DISABLE_SHARED_GEMS" => "true",
      },
    ]]
    (stage / "vendor/bundle/ruby/4.0.0").directory?
    archiver.packaged == [[released, stage, root / "store/ai-flow", acceptance]]
    packed == Dev::Lifecycle::PackedArchive.new(archive: root / "store/ai-flow.zip")
    packager.to_s == "archive, vendored"
    packager.deprecations == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "through the real Archive, the asset carries the vendored bundle the installer will find" do
    Given
    root = Pathname(Dir.mktmpdir("vendored-packager-"))
    stage = tool_stage(root)
    exec = RecordingToolchainExec.new(effect: ->(_argv, env) { Pathname(env.fetch("BUNDLE_PATH")).join("ruby/4.0.0/gems").mkpath })
    archive = Dev::Lifecycle::Archive.new(form: Dev::Lifecycle::Archive::Form::Tar.new)
    packager = Dev::Lifecycle::VendoredPackager.new(packager: archive, exec: exec)

    When
    packed = packager.package(build("rspock"), stage, root / "store/ai-flow")

    Then
    packed.archive == root / "store/ai-flow.tar.zst"
    listing, = Open3.capture2("sh", "-c", "zstd -d -c #{packed.archive} | tar -tf -")
    listing.lines.map(&:chomp).include?("./vendor/bundle/ruby/4.0.0/gems/")
    listing.lines.map(&:chomp).include?("./deps.lock")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a stage that is not self-contained is NotSelfContainedError, naming the two files it lacks, before anything runs" do
    Given
    root = Pathname(Dir.mktmpdir("vendored-packager-"))
    stage = root / "stage"
    stage.mkpath
    (stage / "game.exe").write("exe")
    exec = RecordingToolchainExec.new
    archiver = RecordingPackager.new
    packager = Dev::Lifecycle::VendoredPackager.new(packager: archiver, exec: exec)

    When
    packager.package(build("cellbound-3d-win64-release"), stage, root / "store/cellbound-3d-win64-release")

    Then
    error = raises(Dev::Lifecycle::VendoredPackager::NotSelfContainedError)
    error.message.include?(stage.to_s)
    error.message.include?("dependencies.rb and deps.lock")
    exec.calls.empty?
    archiver.packaged.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a bundle that fails is the gem bundle's VendorError and nothing is archived" do
    Given
    root = Pathname(Dir.mktmpdir("vendored-packager-"))
    stage = tool_stage(root)
    archiver = RecordingPackager.new
    packager = Dev::Lifecycle::VendoredPackager.new(packager: archiver, exec: RecordingToolchainExec.new(fail: true))

    When
    packager.package(build("rspock"), stage, root / "store/ai-flow")

    Then
    raises(Dev::Deps::SelfContainedTree::GemBundle::VendorError)
    archiver.packaged.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end
end
