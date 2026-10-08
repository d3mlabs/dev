# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/legacy"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::LegacyTest < Minitest::Test
  test "sweep removes the flat gem- symlinks of the old layout and nothing else" do
    Given "a project skills dir mixing legacy links with the repo's own content and the dev/ subtree"
    dir = Dir.mktmpdir("dev-skills-legacy-test-")
    skills = Pathname(dir) / ".agents" / "skills"
    FileUtils.mkdir_p(skills / "dev" / "gem" / "rspock")
    FileUtils.mkdir_p(skills / "gem-looking-dir")
    File.symlink("/nowhere/rspock", skills / "gem-rspock--rspock")
    File.symlink("/nowhere/other", skills / "gem-other--thing")
    File.symlink("/nowhere/mine", skills / "mine")
    (skills / "README.md").write("ours\n")

    When "sweeping"
    removed = Dev::Skills::Legacy.sweep(dir)

    Then "both legacy links are gone and reported; everything else stands"
    removed == [skills / "gem-other--thing", skills / "gem-rspock--rspock"]
    !File.symlink?(skills / "gem-rspock--rspock")
    !File.symlink?(skills / "gem-other--thing")
    File.symlink?(skills / "mine")
    (skills / "README.md").file?
    (skills / "gem-looking-dir").directory?
    (skills / "dev" / "gem" / "rspock").directory?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sweep is a no-op on a project without a skills dir" do
    Given "an empty project"
    dir = Dir.mktmpdir("dev-skills-legacy-test-")

    Expect "nothing removed, nothing created"
    Dev::Skills::Legacy.sweep(dir) == []
    Dir.children(dir).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
