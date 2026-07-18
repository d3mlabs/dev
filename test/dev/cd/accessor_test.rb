# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cd"
require "stringio"
require "tmpdir"
require "fileutils"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Cd::AccessorTest < Minitest::Test
  # @param root [String]
  # @param relative [String]
  # @return [Pathname]
  def make_git_repo(root, relative)
    path = Pathname(root) / relative
    FileUtils.mkdir_p(path)
    FileUtils.mkdir_p(path / ".git")
    path
  end

  # @param relative_paths [Array<String>]
  # @return [Array(String, Dev::Cd::Accessor)]
  def build_accessor(*relative_paths)
    dir = Dir.mktmpdir("dev-cd-accessor-")
    relative_paths.each { |rel| make_git_repo(dir, rel) }
    workspace = Dev::Cd::Workspace.new(root: dir)
    [dir, Dev::Cd::Accessor.new(workspace: workspace, matcher: Dev::Cd::Matcher.new(workspace: workspace))]
  end

  test "--resolve prints the absolute path on success" do
    Given "a unique checkout"
    dir, accessor = build_accessor("github.com/d3mlabs/widgets")
    out = StringIO.new
    err = StringIO.new

    When "resolving"
    status = accessor.run(["--resolve", "widgets"], out:, err:)

    Then
    status == 0
    out.string.strip == (Pathname(dir) / "github.com" / "d3mlabs" / "widgets").to_s
    err.string == ""

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--resolve exits non-zero with a clear message on no match" do
    Given "an empty search root"
    dir, accessor = build_accessor
    out = StringIO.new
    err = StringIO.new

    When
    status = accessor.run(["--resolve", "missing"], out:, err:)

    Then
    status == 1
    out.string == ""
    err.string.include?("no repo matching")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--resolve exits non-zero and lists candidates when ambiguous" do
    Given "colliding leaves"
    dir, accessor = build_accessor(
      "github.com/d3mlabs/dev",
      "github.com/someone/dev",
    )
    out = StringIO.new
    err = StringIO.new

    When
    status = accessor.run(["--resolve", "dev"], out:, err:)

    Then
    status == 1
    err.string.include?("ambiguous")
    err.string.include?("d3mlabs/dev")
    err.string.include?("someone/dev")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--complete prints candidates one per line" do
    Given "unique leaves"
    dir, accessor = build_accessor(
      "github.com/d3mlabs/alpha",
      "github.com/d3mlabs/beta",
    )
    out = StringIO.new

    When
    status = accessor.run(["--complete", ""], out:)

    Then
    status == 0
    out.string.lines.map(&:chomp) == ["alpha", "beta"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "missing args print usage and exit 1" do
    Given "an accessor"
    accessor = Dev::Cd::Accessor.new(workspace: Dev::Cd::Workspace.new(root: "/tmp"))
    err = StringIO.new

    When
    status = accessor.run([], out: StringIO.new, err:)

    Then
    status == 1
    err.string.include?("usage: dev cd")
  end
end
