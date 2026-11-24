# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/target_parser"
require "dev/lifecycle"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

# dev's own two targets (dev.yml `targets:`, dev#429, dev#675) ship what the
# d3mlabs tap's two formulas install from — so their file sets are a
# contract, pinned here by running the real ports over this checkout: the
# identity builder stages the tracked files, each target's `files:`
# selection is archived, and the archive is listed. The deployment's set
# carries a keg payload (README, LICENSE) on purpose: its two etc files
# land outside the keg, and brew refuses an empty one (dev#517).
transform!(RSpock::AST::Transformation)
class Dev::OwnTargetsTest < Minitest::Test
  DEV_ROOT = Pathname(File.expand_path("../..", __dir__))

  def setup
    @root = Pathname(Dir.mktmpdir("dev-own-targets-"))
    @targets = Dev::Cli::TargetParser.new.parse_all(YAML.safe_load_file(DEV_ROOT / "dev.yml").fetch("targets"))
    @ports = Dev::Lifecycle::Ports.new(project_root: DEV_ROOT)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  # Build and package one of dev's targets into the temp store.
  #
  # @param name [String]
  # @return [Array<String>] the zip's entries, sorted
  def archive_entries(name)
    target = @targets.fetch(name)
    build = target.default_build
    install = @root / name / "install"
    @ports.builder_for(target).build(build, install)
    packed = @ports.packager_for(target).package(build, install, @root / name / "store" / name)
    Open3.capture2("unzip", "-Z1", packed.archive.to_s).first.lines.map(&:chomp).sort
  end

  test "neither target declares a build: script — the checkout is the stage and files: selects what ships" do
    Expect
    @targets.keys == ["dev-core", "dev"]
    @targets.values.none?(&:buildable?)
    @targets.values.all? { |target| target.packager.is_a?(Dev::Lifecycle::PackagerSpec::Archive) }
    @targets.values.none? { |target| target.packager.files.whole? }
    (DEV_ROOT / "bin").children.map { |path| path.basename.to_s }.grep(/\Ainstall-/).empty?
  end

  test "dev-core ships the org-blank tool: bin, lib, share, VERSION, LICENSE, README — and nothing of the checkout's manifest, locks or org payload" do
    When
    entries = archive_entries("dev-core")

    Then
    entries.map { |entry| entry.split("/").first }.uniq.sort == %w[LICENSE README.md VERSION bin lib share]
    entries.include?("bin/dev")
    entries.include?("lib/dev/lifecycle/archive.rb")
    entries.include?("VERSION")
    entries.none? { |entry| %w[dev.yml deps.lock dependencies.rb Gemfile deploy/ test/].any? { |kept_out| entry.start_with?(kept_out) } }
  end

  test "dev ships the d3mlabs payload at its checkout paths — deploy/d3mlabs/config.yml and Brewfile — with the keg payload brew needs beside it (dev#517)" do
    When
    entries = archive_entries("dev")

    Then
    entries == %w[LICENSE README.md deploy/ deploy/d3mlabs/ deploy/d3mlabs/Brewfile deploy/d3mlabs/config.yml]
  end
end
