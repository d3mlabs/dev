# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/tap"
require "dev/deps/tap_clone"
require "dev/lifecycle/git"
require "fileutils"
require "pathname"
require "tmpdir"

# The clone against a real tap: a bare origin seeded with a formula, in a
# temp dir. Nothing here is worth mocking.
transform!(RSpock::AST::Transformation)
class Dev::Deps::TapCloneTest < Minitest::Test
  GIT = Dev::Lifecycle::Git

  def setup
    @workspace = Pathname(Dir.mktmpdir("tap-clone-"))
    @origin = @workspace / "homebrew-d3mlabs.git"
    @seed = @workspace / "seed"
    GIT.new(root: @workspace).capture(["init", "-q", "--bare", "-b", "main", @origin.to_s])
    @seed.mkpath
    seed_git = GIT.new(root: @seed)
    seed_git.capture(["init", "-q", "-b", "main"])
    seed_git.capture(["config", "user.name", "t"])
    seed_git.capture(["config", "user.email", "t@t"])
    (@seed / "Formula").mkpath
    (@seed / "Formula" / "dev.rb").write("class Dev < Formula\n  url \"https://x/dev-0.7.13.zip\"\n  sha256 \"#{"ab" * 32}\"\nend\n")
    seed_git.capture(["add", "."])
    seed_git.capture(["commit", "-q", "-m", "dev: 0.7.13"])
    seed_git.capture(["remote", "add", "origin", @origin.to_s])
    seed_git.capture(["push", "-q", "-u", "origin", "main"])
    @tap = Dev::Deps::Tap.new(name: "d3mlabs/d3mlabs", url: "file://#{@origin}")
    @clone = Dev::Deps::TapClone.new(tap: @tap, dir: @workspace / "scratch" / "d3mlabs" / "homebrew-d3mlabs")
  end

  def teardown
    FileUtils.rm_rf(@workspace)
    super
  end

  def origin_head = GIT.new(root: @origin).capture(["rev-parse", "main"]).strip
  def clone_git = GIT.new(root: @clone.dir)

  def push_from_seed(message)
    (@seed / "Formula" / "dev.rb").write("class Dev < Formula\n  url \"https://x/#{message}.zip\"\n  sha256 \"#{"cd" * 32}\"\nend\n")
    seed_git = GIT.new(root: @seed)
    seed_git.capture(["commit", "-q", "-am", message])
    seed_git.capture(["push", "-q", "origin", "main"])
  end

  test "the remote url is the tap's own when declared, else its GitHub repository under brew's naming" do
    Expect
    @clone.remote_url == "file://#{@origin}"
    Dev::Deps::TapClone.new(tap: Dev::Deps::Tap.new(name: "acme/tools"), dir: @workspace / "x").remote_url ==
      "https://github.com/acme/homebrew-tools.git"
  end

  test "sync! clones an absent tap into its directory, on the remote's default branch, and finds its formulas" do
    When
    @clone.sync!

    Then
    (@clone.dir / ".git").directory?
    @clone.branch == "main"
    @clone.head == origin_head
    @clone.formula("dev").path == @clone.dir / "Formula" / "dev.rb"
  end

  test "sync! on an existing clone moves it to the tap's tip, discarding a rewrite whose commit never pushed" do
    Given "a clone with a stale rewrite in its tree and a commit the tap never received"
    @clone.sync!
    stale = @clone.formula("dev")
    stale.path.write("rewritten but never committed\n")
    clone_git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "local only"])
    push_from_seed("dev-0.7.14")

    When
    @clone.sync!

    Then "the clone is exactly the tap's tip"
    @clone.head == origin_head
    stale.path.read.include?("dev-0.7.14")
    clone_git.capture(["status", "--porcelain"]).strip.empty?
  end

  test "a formula the tap does not carry is refused, naming the file and that dev does not author one" do
    Given
    @clone.sync!

    When
    @clone.formula("dev-core")

    Then
    error = raises(Dev::Deps::TapClone::FormulaMissingError)
    error.message.include?("d3mlabs/d3mlabs carries no Formula/dev-core.rb")
    error.message.include?("does not author one")
  end

  test "commit! then push! publishes the rewritten formulas to the tap's default branch" do
    Given
    @clone.sync!
    clone_git.capture(["config", "user.name", "t"])
    clone_git.capture(["config", "user.email", "t@t"])
    formula = @clone.formula("dev")
    formula.path.write("class Dev < Formula\n  url \"https://x/dev-0.8.0.zip\"\n  sha256 \"#{"ef" * 32}\"\nend\n")

    When
    @clone.commit!(message: "dev: 0.8.0", files: [formula])
    @clone.push!

    Then
    origin_head == @clone.head
    GIT.new(root: @origin).capture(["log", "-1", "--format=%s", "main"]).strip == "dev: 0.8.0"
    GIT.new(root: @origin).capture(["show", "main:Formula/dev.rb"]).include?("dev-0.8.0.zip")
  end

  test "a push the tap refuses (it moved since the sync) is git's own error" do
    Given
    @clone.sync!
    clone_git.capture(["config", "user.name", "t"])
    clone_git.capture(["config", "user.email", "t@t"])
    formula = @clone.formula("dev")
    formula.path.write("class Dev < Formula\n  url \"https://x/dev-0.8.0.zip\"\n  sha256 \"#{"ef" * 32}\"\nend\n")
    @clone.commit!(message: "dev: 0.8.0", files: [formula])
    push_from_seed("dev-0.7.14")

    When
    @clone.push!

    Then
    raises(Dev::Lifecycle::Git::CommandFailedError)
  end
end
