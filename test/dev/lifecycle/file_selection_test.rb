# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::FileSelectionTest < Minitest::Test
  SELECTION = Dev::Lifecycle::FileSelection

  # A stage shaped like a checkout: a tool's tree with a lock, docs, a
  # nested scratch directory, dotfiles and a symlink.
  #
  # @param root [Pathname]
  # @return [Pathname] the stage
  def stage_under(root)
    stage = root / "stage"
    %w[bin/dev lib/dev.rb lib/dev/cli.rb lib/scratch/tmp.rb share/skills/a.md VERSION LICENSE README.md
       deploy/d3mlabs/config.yml deploy/d3mlabs/Brewfile dev.yml deps.lock .gitignore .github/workflows/ci.yml].each do |relative|
      (stage / relative).dirname.mkpath
      (stage / relative).write(relative)
    end
    File.symlink("dev.rb", stage / "lib/alias.rb")
    stage
  end

  def selected(stage, *sources)
    SELECTION.parse(sources).select(stage).map(&:to_s)
  end

  test "a positive list starts from nothing: a directory means its contents, a file its path, all at stage paths in directory order" do
    Given
    root = Pathname(Dir.mktmpdir("file-selection-"))
    stage = stage_under(root)

    Expect
    selected(stage, "/bin", "/lib", "/VERSION") == ["VERSION", "bin/dev", "lib/alias.rb", "lib/dev/cli.rb", "lib/dev.rb", "lib/scratch/tmp.rb"]
    selected(stage, "deploy/d3mlabs/config.yml", "deploy/d3mlabs/Brewfile") == ["deploy/d3mlabs/Brewfile", "deploy/d3mlabs/config.yml"]
    # Unanchored, as in gitignore, a name matches at any depth.
    selected(stage, "a.md") == ["share/skills/a.md"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "patterns apply in order, the last match deciding: a negation after a directory carves it, a positive after a negation restores" do
    Given
    root = Pathname(Dir.mktmpdir("file-selection-"))
    stage = stage_under(root)

    Expect
    selected(stage, "lib", "!lib/scratch") == ["lib/alias.rb", "lib/dev/cli.rb", "lib/dev.rb"]
    selected(stage, "lib", "!lib/scratch", "lib/scratch/tmp.rb") == ["lib/alias.rb", "lib/dev/cli.rb", "lib/dev.rb", "lib/scratch/tmp.rb"]
    selected(stage, "!lib/scratch", "lib") == ["lib/alias.rb", "lib/dev/cli.rb", "lib/dev.rb", "lib/scratch/tmp.rb"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a list with no positive pattern starts from everything, like a .npmignore; dotfiles count" do
    Given
    root = Pathname(Dir.mktmpdir("file-selection-"))
    stage = stage_under(root)

    Expect
    selected(stage, "!deploy", "!*.lock", "!.github", "!lib/scratch/") ==
      [".gitignore", "LICENSE", "README.md", "VERSION", "bin/dev", "dev.yml", "lib/alias.rb", "lib/dev/cli.rb", "lib/dev.rb", "share/skills/a.md"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the identity is the whole stage: every file and symlink, an empty stage selecting nothing without refusing" do
    Given
    root = Pathname(Dir.mktmpdir("file-selection-"))
    stage = stage_under(root)
    empty = root / "empty"
    empty.mkpath

    Expect
    SELECTION.all.whole?
    !SELECTION.parse(["bin"]).whole?
    SELECTION.all.select(stage).size == 15
    SELECTION.all.select(stage).include?(Pathname("lib/alias.rb"))
    SELECTION.all.select(empty) == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a list selecting nothing is refused with the patterns and the stage named" do
    Given
    root = Pathname(Dir.mktmpdir("file-selection-"))
    stage = stage_under(root)

    When
    SELECTION.parse(["exe", "!lib", "*.gem"]).select(stage)

    Then
    error = raises(SELECTION::EmptySelectionError)
    error.message == "files: exe !lib *.gem selects nothing in #{stage}"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "parse hands an invalid pattern's refusal through" do
    When
    SELECTION.parse(["bin", "!"])

    Then
    raises Dev::Lifecycle::FilePattern::InvalidFilePatternError
  end

  test "selections render after the archive's form, the identity as nothing, and are values over their patterns in order" do
    Expect
    SELECTION.all.to_s == ""
    SELECTION.parse(["bin", "!lib/scratch"]).to_s == ", files: bin !lib/scratch"
    SELECTION.all == SELECTION.parse([])
    SELECTION.parse(["bin", "lib"]) == SELECTION.parse(["bin", "lib"])
    SELECTION.parse(["bin", "lib"]).hash == SELECTION.parse(["bin", "lib"]).hash
    SELECTION.parse(["bin", "lib"]) != SELECTION.parse(["lib", "bin"])
    SELECTION.parse(["bin"]) != SELECTION.all
  end
end
