# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/brew_publisher"
require "dev/deps/tap"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "pathname"
require "support/fake_gh"
require "time"
require "tmpdir"

# The brew publisher against a real tap (a bare origin in a temp dir, a
# clone in the channel's scratch) and a scripted forge (FakeGh answers the
# asset urls). The formulas are dev-core.rb's and dev.rb's shapes.
transform!(RSpock::AST::Transformation)
class Dev::Deps::BrewPublisherTest < Minitest::Test
  GIT = Dev::Lifecycle::Git
  TAG = Dev::Lifecycle::ReleaseTag.new("0.8.0")
  RELEASE_SHA = "3f2a1c9d8e7b4455"
  DOWNLOADS = "https://github.com/d3mlabs/dev/releases/download/v0.8.0"
  SOURCE_TARBALL = "https://github.com/d3mlabs/dev/archive/refs/tags/v0.7.13.tar.gz"
  OLD_SHA = "6e1217f48a323da2e4dd1fac4c7e7d761aa60b39b0e4f2afb784459d5fc1f493"
  RESOURCE_SHA = "e36147f2e8088796b996f0560f577bd1599f2b6aa3c374fe09fff59af5589c35"

  DEV_CORE_FORMULA = <<~RUBY.freeze
    class DevCore < Formula
      desc "Find repo with dev.yml and run declared commands"
      url "#{SOURCE_TARBALL}"
      sha256 "#{OLD_SHA}"

      resource "cli-ui" do
        url "https://rubygems.org/downloads/cli-ui-2.7.0.gem"
        sha256 "#{RESOURCE_SHA}"
      end
    end
  RUBY

  DEV_FORMULA = <<~RUBY.freeze
    class Dev < Formula
      desc "D3mlabs deployment of the dev CLI"
      url "#{SOURCE_TARBALL}"
      sha256 "#{OLD_SHA}"

      depends_on "d3mlabs/d3mlabs/dev-core"
    end
  RUBY

  def setup
    @workspace = Pathname(Dir.mktmpdir("brew-publisher-"))
    @origin = @workspace / "homebrew-d3mlabs.git"
    @scratch = @workspace / "store" / ".brew"
    @project = @workspace / "project"
    @project.mkpath
    seed_tap
    @tap = Dev::Deps::Tap.new(name: "d3mlabs/d3mlabs", url: "file://#{@origin}")
    @targets = [
      Dev::Lifecycle::Target.new(name: "dev-core", desc: "The org-blank tool"),
      Dev::Lifecycle::Target.new(name: "dev", desc: "The d3mlabs deployment"),
    ]
  end

  def teardown
    FileUtils.rm_rf(@workspace)
    super
  end

  # The tap on its origin, with both formulas at the source tarball.
  def seed_tap
    seed = @workspace / "seed"
    GIT.new(root: @workspace).capture(["init", "-q", "--bare", "-b", "main", @origin.to_s])
    (seed / "Formula").mkpath
    (seed / "Formula" / "dev-core.rb").write(DEV_CORE_FORMULA)
    (seed / "Formula" / "dev.rb").write(DEV_FORMULA)
    git = GIT.new(root: seed)
    git.capture(["init", "-q", "-b", "main"])
    git.capture(["config", "user.name", "t"])
    git.capture(["config", "user.email", "t@t"])
    git.capture(["add", "."])
    git.capture(["commit", "-q", "-m", "dev: 0.7.13"])
    git.capture(["remote", "add", "origin", @origin.to_s])
    git.capture(["push", "-q", "-u", "origin", "main"])
  end

  # The publisher's clone, made ahead so the commit has an identity — as
  # the operator's clone would through their global git config.
  def prepare_clone
    dir = @scratch / "d3mlabs" / "homebrew-d3mlabs"
    dir.parent.mkpath
    GIT.new(root: dir.parent).capture(["clone", "-q", "file://#{@origin}", "homebrew-d3mlabs"])
    GIT.new(root: dir).capture(["config", "user.name", "t"])
    GIT.new(root: dir).capture(["config", "user.email", "t@t"])
    dir
  end

  def channel
    Dev::Lifecycle::Channel.new(
      name: "brew", desc: "The tap", accepts: @targets.map { |target| Dev::Lifecycle::BuildPattern.new(target:) },
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "brew"),
    )
  end

  def release_shipment(build_name, bytes: "zip of #{build_name}")
    build = Dev::Lifecycle::Build.parse(build_name, @targets)
    name = "#{build_name}-0.8.0.zip"
    archive = @workspace / "store" / ".releases" / "v0.8.0" / name
    archive.dirname.mkpath
    archive.write(bytes)
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build:, name:, sha256: Digest::SHA256.hexdigest(bytes), build_id: Dev::Lifecycle::BuildId.new("0.8.0+#{RELEASE_SHA[0, 12]}"),
    )
    Dev::Lifecycle::Shipment.of_release(entry, archive:, tag: TAG, sha: RELEASE_SHA)
  end

  def store_shipment(build_name)
    dir = @workspace / "store" / build_name
    dir.mkpath
    (dir / "#{build_name}.zip").write("zip")
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.13", now: Time.utc(2026, 11, 8, 12, 0, 0)),
      build: Dev::Lifecycle::Build.parse(build_name, @targets),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: Time.utc(2026, 11, 8, 12, 0, 0),
      builder: "script", builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("0.7.13+3f2a1c9d8e7b"),
      archive: "#{build_name}.zip", archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  # A forge serving v0.8.0's two assets, answered once per lookup.
  def forge(lookups: 2)
    assets = ["dev-core", "dev"].map { |name| { "name" => "#{name}-0.8.0.zip", "url" => "#{DOWNLOADS}/#{name}-0.8.0.zip" } }
    gh = FakeGh.new(root: @project)
    lookups.times { gh.answers(["release", "view", "v0.8.0"], with: assets) }
    gh
  end

  def publisher(gh, taps: [@tap])
    Dev::Deps::BrewPublisher.new(project_root: @project, taps:, releases: Dev::Lifecycle::GithubReleases.new(gh:))
  end

  def origin_git = GIT.new(root: @origin)
  def origin_formula(name) = origin_git.capture(["show", "main:Formula/#{name}.rb"])

  test "a release's archives point each formula of a build's name at that build's asset with release.json's digest, in one commit pushed to the tap" do
    Given "the clone in the scratch, and the forge serving both assets"
    prepare_clone
    gh = forge
    core = release_shipment("dev-core")
    deployment = release_shipment("dev")

    When
    receipt = publisher(gh).publish([core, deployment], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then "both formulas moved from the shared source tarball to their own asset, the resource untouched; the receipt is the tap's commit, the urls the forge's answers"
    origin_formula("dev-core") == DEV_CORE_FORMULA.sub(SOURCE_TARBALL, "#{DOWNLOADS}/dev-core-0.8.0.zip").sub(OLD_SHA, core.archive_sha256)
    origin_formula("dev") == DEV_FORMULA.sub(SOURCE_TARBALL, "#{DOWNLOADS}/dev-0.8.0.zip").sub(OLD_SHA, deployment.archive_sha256)
    origin_formula("dev-core").include?(RESOURCE_SHA)
    origin_git.capture(["log", "--format=%s", "main"]).lines.map(&:strip) == ["dev-core, dev: 0.8.0", "dev: 0.7.13"]
    receipt == Dev::Lifecycle::Receipt.new(summary: "d3mlabs/d3mlabs@#{origin_git.capture(["rev-parse", "main"]).strip[0, 12]}: dev-core, dev → v0.8.0")
    gh.calls.map(&:argv).uniq == [["release", "view", "v0.8.0", "--json", "assets", "--jq", ".assets"]]
  end

  test "a formula already at the release is left alone: a second deploy commits nothing and says so" do
    Given "a first deploy done"
    prepare_clone
    publisher(forge).publish([release_shipment("dev-core"), release_shipment("dev")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)
    published = origin_git.capture(["rev-parse", "main"]).strip

    When
    receipt = publisher(forge).publish([release_shipment("dev-core"), release_shipment("dev")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    receipt == Dev::Lifecycle::Receipt.new(summary: "d3mlabs/d3mlabs already points at v0.8.0: dev-core, dev")
    origin_git.capture(["rev-parse", "main"]).strip == published
  end

  test "only the formulas that moved are committed: one already at the release, the other not" do
    Given "dev-core already published, dev not"
    prepare_clone
    publisher(forge(lookups: 1)).publish([release_shipment("dev-core")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    When
    receipt = publisher(forge).publish([release_shipment("dev-core"), release_shipment("dev")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    receipt.summary.end_with?(": dev → v0.8.0")
    origin_git.capture(["log", "-1", "--format=%s", "main"]).strip == "dev: 0.8.0"
  end

  test "the clone is made in the scratch when absent, under brew's own layout, before any formula is read" do
    Given "no clone yet, and a build the tap has no formula for — so the run ends right after the clone"
    @targets << Dev::Lifecycle::Target.new(name: "dev-extra", desc: "No formula")

    When
    publisher(forge(lookups: 0)).publish([release_shipment("dev-extra")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    raises(Dev::Deps::TapClone::FormulaMissingError)
    (@scratch / "d3mlabs" / "homebrew-d3mlabs" / ".git").directory?
    (@scratch / "d3mlabs" / "homebrew-d3mlabs" / "Formula" / "dev.rb").file?
  end

  test "a working artifact from the store is refused: a formula points at a release asset, never at a store file" do
    Given
    prepare_clone

    When
    publisher(forge(lookups: 0)).publish([store_shipment("dev-core")], channel:, track: Dev::Lifecycle::Track::Testing, scratch: @scratch)

    Then
    error = raises(Dev::Deps::BrewPublisher::WorkingArtifactError)
    error.message.include?("from the store (the testing track)")
    error.message.include?("dev deploy brew --release <version>")
    origin_git.capture(["log", "--format=%s", "main"]).lines.length == 1
  end

  test "a lock pinning from #{what} has no destination" do
    Given
    taps = names.map { |name| Dev::Deps::Tap.new(name:) }

    When
    publisher(forge(lookups: 0), taps:).publish([release_shipment("dev-core")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    e = raises(error)
    names.all? { |name| e.message.include?(name) }

    Where
    what           | names                                | error
    "no tap"       | []                                   | Dev::Deps::BrewPublisher::NoTapError
    "several taps" | ["d3mlabs/d3mlabs", "acme/tools"]    | Dev::Deps::BrewPublisher::AmbiguousTapError
  end

  test "a build whose formula the tap does not carry is refused before anything is committed" do
    Given "a third target the tap has no formula for"
    prepare_clone
    @targets << Dev::Lifecycle::Target.new(name: "dev-extra", desc: "No formula")
    gh = forge(lookups: 2).answers(["release", "view", "v0.8.0"], with: [{ "name" => "dev-extra-0.8.0.zip", "url" => "#{DOWNLOADS}/dev-extra-0.8.0.zip" }])

    When
    publisher(gh).publish([release_shipment("dev-core"), release_shipment("dev-extra")], channel:, track: Dev::Lifecycle::Track::Live, scratch: @scratch)

    Then
    raises(Dev::Deps::TapClone::FormulaMissingError)
    origin_git.capture(["log", "--format=%s", "main"]).lines.length == 1
  end

  test "to_s is the channel's name, as dev help renders a protocol" do
    Expect
    publisher(forge(lookups: 0)).to_s == "brew"
  end
end
