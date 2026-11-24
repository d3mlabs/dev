# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

# The identity builder over real repositories in temporary directories:
# what `git ls-files` lists is what reaches the stage, as the working tree
# holds it.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::CheckoutBuilderTest < Minitest::Test
  include LifecycleFixtures

  def setup
    @root = Pathname(Dir.mktmpdir("checkout-builder-"))
    @project = @root / "project"
    @project.mkpath
    @install = @root / "store/rspock/install"
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args, chdir: @project)
    out, err, status = Open3.capture3("git", "-C", chdir.to_s, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out
  end

  def write(relative, content, mode: nil)
    path = @project / relative
    path.dirname.mkpath
    path.write(content)
    path.chmod(mode) if mode
  end

  def staged
    @install.glob("**/*", File::FNM_DOTMATCH).reject(&:directory?).map { |path| path.relative_path_from(@install).to_s }.sort
  end

  test "the tracked files reach the stage in their layout, modes and symlinks kept; untracked and ignored files never do" do
    Given "a repo tracking a layout, with ignored and untracked files beside it"
    git("init", "-q")
    write("bin/tool", "#!/bin/sh\necho hi\n", mode: 0o755)
    write("lib/tool.rb", "puts 1\n")
    write("VERSION", "1.0.0\n")
    write(".gitignore", "coverage/\nvendor/\n")
    File.symlink("tool.rb", (@project / "lib/alias.rb").to_s)
    git("add", ".")
    git("commit", "-q", "-m", "one")
    write("coverage/index.html", "<html>")
    write("vendor/bundle/x.rb", "x")
    write("scratch.txt", "untracked")
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    When
    builder.build(build("rspock"), @install)

    Then "exactly the tracked paths, as files with their content and mode, the symlink as a symlink"
    staged == [".gitignore", "VERSION", "bin/tool", "lib/alias.rb", "lib/tool.rb"]
    (@install / "bin/tool").read == "#!/bin/sh\necho hi\n"
    (@install / "bin/tool").executable?
    (@install / "lib/alias.rb").symlink?
    File.readlink((@install / "lib/alias.rb").to_s) == "tool.rb"
    !(@install / "coverage").exist?
    !(@install / "vendor").exist?
    !(@install / "scratch.txt").exist?
  end

  test "the stage is the working tree's content: a modified tracked file ships as edited, a deleted one not at all" do
    Given "a commit, then an edit and a deletion left uncommitted"
    git("init", "-q")
    write("a.txt", "committed\n")
    write("b.txt", "gone\n")
    git("add", ".")
    git("commit", "-q", "-m", "one")
    write("a.txt", "edited\n")
    (@project / "b.txt").delete
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    When
    builder.build(build("rspock"), @install)

    Then
    staged == ["a.txt"]
    (@install / "a.txt").read == "edited\n"
  end

  test "a gitlink — a nested repository the index records as a directory entry — is not a file of this checkout and is skipped" do
    Given "a nested repo added to the outer index"
    git("init", "-q")
    write("a.txt", "a\n")
    nested = @project / "nested"
    nested.mkpath
    git("init", "-q", chdir: nested)
    (nested / "inner.txt").write("inner\n")
    git("add", ".", chdir: nested)
    git("commit", "-q", "-m", "inner", chdir: nested)
    git("add", ".")
    git("commit", "-q", "-m", "outer")
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    When
    builder.build(build("rspock"), @install)

    Then
    git("ls-files", "-s", "nested").start_with?("160000")
    staged == ["a.txt"]
  end

  test "a previous build's files are gone from the stage: the checkout as it is now is the whole install" do
    Given "a stage holding a file from an earlier build"
    git("init", "-q")
    write("a.txt", "a\n")
    git("add", ".")
    git("commit", "-q", "-m", "one")
    @install.mkpath
    (@install / "stale.txt").write("from before")
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    When
    builder.build(build("rspock"), @install)

    Then
    staged == ["a.txt"]
  end

  test "a project root outside any git checkout has no tracked files to stage, and says so" do
    Given
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    When
    builder.build(build("rspock"), @install)

    Then
    error = raises Dev::Lifecycle::CheckoutBuilder::NotACheckoutError
    error.message == "#{@project} is not a git checkout, so a target with no `builder:` has no tracked files to stage"
  end

  test "the builder's traits: named checkout for the manifest and for help, no version, no target options" do
    Given
    builder = Dev::Lifecycle::CheckoutBuilder.new(project_root: @project)

    Expect
    builder.name == "checkout"
    builder.to_s == "checkout"
    builder.version.nil?
    builder.target_options_schema == []
  end
end
