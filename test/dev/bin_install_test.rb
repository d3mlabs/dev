# typed: false
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

# dev's own two builders (dev.yml `targets:`, dev#429) lay out what the
# d3mlabs tap's two formulas install from — so their file sets are a
# contract, pinned here by running the real scripts into a temp install.
# The deployment's set carries a keg payload (README, LICENSE) on purpose:
# its two etc files land outside the keg, and brew refuses an empty one
# (dev#517).
transform!(RSpock::AST::Transformation)
class Dev::BinInstallTest < Minitest::Test
  DEV_ROOT = Pathname(File.expand_path("../..", __dir__))

  def setup
    @install = Pathname(Dir.mktmpdir("dev-install-"))
    (@install / "stale-from-last-time").write("x")
  end

  def teardown
    FileUtils.rm_rf(@install)
    super
  end

  def run_builder(name)
    out, status = Open3.capture2e({ "DEV_TARGET" => name, "DEV_INSTALL" => @install.to_s }, (DEV_ROOT / "bin" / "install-#{name}").to_s)
    [out, status]
  end

  def installed = @install.children.map { |child| child.basename.to_s }.sort

  test "install-core lays out the org-blank tool: bin, lib, share, VERSION, LICENSE, README — replacing whatever the install held" do
    When
    out, status = run_builder("core")

    Then
    status.success?
    out == ""
    installed == %w[LICENSE README.md VERSION bin lib share]
    (@install / "VERSION").read == (DEV_ROOT / "VERSION").read
    (@install / "bin" / "dev").executable?
  end

  test "install-deployment lays out the d3mlabs payload — config.yml and Brewfile — with the keg payload brew needs beside it: README and LICENSE (dev#517)" do
    When
    out, status = run_builder("deployment")

    Then
    status.success?
    out == ""
    installed == %w[Brewfile LICENSE README.md config.yml]
    (@install / "config.yml").read == (DEV_ROOT / "deploy" / "d3mlabs" / "config.yml").read
    (@install / "Brewfile").read == (DEV_ROOT / "deploy" / "d3mlabs" / "Brewfile").read
  end
end
