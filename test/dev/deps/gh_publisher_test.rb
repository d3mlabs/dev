# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gh_publisher"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "support/fake_gh"
require "support/tool_tree_fixtures"
require "time"
require "tmpdir"

# The gh publisher over a scripted forge: FakeGh answers the release's
# facts, the tag listing and the latest designation, and records the
# writes. A deploy moves heads only, so nothing on disk is touched; a
# tree's acceptance at package reads the tree and asks the forge nothing.
transform!(RSpock::AST::Transformation)
class Dev::Deps::GhPublisherTest < Minitest::Test
  include ToolTreeFixtures

  REFS = "repos/{owner}/{repo}/git/matching-refs/tags/v"
  FACTS = "repos/{owner}/{repo}/releases/tags/"
  SHA_110 = "1" * 40
  SHA_120 = "2" * 40
  SHA_130 = "3" * 40
  SHA_200 = "a" * 40

  def setup
    @workspace = Pathname(Dir.mktmpdir("gh-publisher-"))
    @project = @workspace / "project"
    @project.mkpath
    @targets = [Dev::Lifecycle::Target.new(name: "dev", desc: "The tool")]
  end

  def teardown
    FileUtils.rm_rf(@workspace)
    super
  end

  def channel
    Dev::Lifecycle::Channel.new(
      name: "gh", desc: "The series tags", accepts: @targets.map { |target| Dev::Lifecycle::BuildPattern.new(target:) },
      publisher: Dev::Lifecycle::PublisherSpec::Integration.new(name: "gh"),
    )
  end

  def release_shipment(version, sha)
    build = Dev::Lifecycle::Build.parse("dev", @targets)
    name = "dev-#{version}.zip"
    archive = @workspace / "store" / ".releases" / "v#{version}" / name
    archive.dirname.mkpath
    archive.write("zip")
    entry = Dev::Lifecycle::Manifest::Release::Archive.new(
      build:, name:, sha256: Digest::SHA256.hexdigest("zip"), build_id: Dev::Lifecycle::BuildId.new("#{version}+#{sha[0, 12]}"),
    )
    Dev::Lifecycle::Shipment.of_release(entry, archive:, tag: Dev::Lifecycle::ReleaseTag.new(version), sha:)
  end

  def store_shipment
    dir = @workspace / "store" / "dev"
    dir.mkpath
    (dir / "dev.zip").write("zip")
    manifest = Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.13", now: Time.utc(2026, 11, 8, 12, 0, 0)),
      build: Dev::Lifecycle::Build.parse("dev", @targets),
      state: Dev::Lifecycle::GitState.new(sha: "3f2a1c9d8e7b", dirty: false),
      packaged_at: Time.utc(2026, 11, 8, 12, 0, 0),
      builder: "script", builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("0.7.13+3f2a1c9d8e7b"),
      archive: "dev.zip", archive_sha256: "ab" * 32,
    )
    Dev::Lifecycle::Shipment.of_artifact(Dev::Lifecycle::Artifact.new(dir:, manifest:))
  end

  # The forge as a deploy reads it: the release's facts, every v-tag at
  # its commit, the latest designation (nil for none), and the writes
  # accepted.
  def forge(version, immutable: true, prerelease: false, tags: {}, latest: nil)
    gh = FakeGh.new(root: @project)
    gh.answers(["api", "#{FACTS}v#{version}"], with: { "immutable" => immutable, "prerelease" => prerelease })
    lines = tags.map { |name, sha| JSON.generate({ "ref" => "refs/tags/#{name}", "object" => { "sha" => sha, "type" => "commit" } }) }
    gh.answers(["api", "--paginate", REFS], with: lines.join("\n") + "\n")
    latest ? gh.answers(["release", "view"], with: "#{latest}\n") : gh.refuses(["release", "view"], with: "release not found")
    gh.answers(["api", "-X"], with: "{}")
    gh.answers(["release", "edit"], with: "")
    gh
  end

  def publisher(gh)
    Dev::Deps::GhPublisher.new(
      project_root: @project, releases: Dev::Lifecycle::GithubReleases.new(gh:), heads: Dev::Lifecycle::GithubHeads.new(gh:),
    )
  end

  # The forge's writes: `(method, path, body)` for the API, the argv for `release edit`.
  def writes(gh)
    gh.calls.filter_map do |call|
      next [call.argv[2], call.argv.last, JSON.parse(call.stdin)] if call.argv.first(2) == ["api", "-X"]

      call.argv if call.argv.first(2) == ["release", "edit"]
    end
  end

  def publish(gh, shipment)
    publisher(gh).publish([shipment], channel:, track: Dev::Lifecycle::Track::Live, scratch: @workspace / "scratch")
  end

  def preview(gh, shipment)
    publisher(gh).preview([shipment], channel:, track: Dev::Lifecycle::Track::Live)
  end

  test "deploying a newer release of the newest series moves its series tag by force and hands it the latest designation; the hint names the followers" do
    Given "v1 at 1.2.0, the latest"
    gh = forge("1.3.0", tags: { "v1" => SHA_120, "v1.2.0" => SHA_120, "v1.3.0" => SHA_130 }, latest: "v1.2.0")

    When
    receipt = publish(gh, release_shipment("1.3.0", SHA_130))

    Then
    writes(gh) == [
      ["PATCH", "repos/{owner}/{repo}/git/refs/tags/v1", { "sha" => SHA_130, "force" => true }],
      ["release", "edit", "v1.3.0", "--latest"],
    ]
    receipt.summary == "v1 → v1.3.0 (#{SHA_130[0, 12]}), from v1.2.0 (#{SHA_120[0, 12]}); latest → v1.3.0"
    receipt.hint == "Followers of v1 (~> 1, @v1) take v1.3.0 from here"
  end

  test "the first deploy of a series creates its tag; with nothing deployed yet it is the newest series and takes latest" do
    Given "a repo with releases and no heads"
    gh = forge("1.2.0", tags: { "v1.1.0" => SHA_110, "v1.2.0" => SHA_120 })

    When
    receipt = publish(gh, release_shipment("1.2.0", SHA_120))

    Then
    writes(gh) == [
      ["POST", "repos/{owner}/{repo}/git/refs", { "ref" => "refs/tags/v1", "sha" => SHA_120 }],
      ["release", "edit", "v1.2.0", "--latest"],
    ]
    receipt.summary == "v1 → v1.2.0 (#{SHA_120[0, 12]}), new; latest → v1.2.0"
  end

  test "a patch of an older series after a newer one is live moves its own tag and leaves latest on the newest series" do
    Given "v2 at 2.0.0 is latest; v1 at 1.2.0"
    gh = forge("1.3.0", tags: { "v1" => SHA_120, "v2" => SHA_200, "v1.2.0" => SHA_120, "v2.0.0" => SHA_200, "v1.3.0" => SHA_130 }, latest: "v2.0.0")

    When
    receipt = publish(gh, release_shipment("1.3.0", SHA_130))

    Then
    writes(gh) == [["PATCH", "repos/{owner}/{repo}/git/refs/tags/v1", { "sha" => SHA_130, "force" => true }]]
    receipt.summary == "v1 → v1.3.0 (#{SHA_130[0, 12]}), from v1.2.0 (#{SHA_120[0, 12]}); latest stays v2.0.0 — v2 is the newest series"
    receipt.hint == "Followers of v1 (~> 1, @v1) take v1.3.0 from here"
  end

  test "deploying an earlier release of the series again moves the tag back — a rollback is a deploy" do
    Given
    gh = forge("1.2.0", tags: { "v1" => SHA_130, "v1.2.0" => SHA_120, "v1.3.0" => SHA_130 }, latest: "v1.3.0")

    When
    receipt = publish(gh, release_shipment("1.2.0", SHA_120))

    Then
    writes(gh) == [
      ["PATCH", "repos/{owner}/{repo}/git/refs/tags/v1", { "sha" => SHA_120, "force" => true }],
      ["release", "edit", "v1.2.0", "--latest"],
    ]
    receipt.summary == "v1 → v1.2.0 (#{SHA_120[0, 12]}), from v1.3.0 (#{SHA_130[0, 12]}); latest → v1.2.0"
  end

  test "a release the heads are already at writes nothing and says so, with no hint: the deploy is idempotent" do
    Given
    gh = forge("1.3.0", tags: { "v1" => SHA_130, "v1.3.0" => SHA_130 }, latest: "v1.3.0")

    When
    receipt = publish(gh, release_shipment("1.3.0", SHA_130))

    Then
    writes(gh) == []
    receipt.summary == "v1 already at v1.3.0; latest already v1.3.0"
    receipt.hint.nil?
  end

  test "a pre-release moves its series tag and is never designated latest" do
    Given
    gh = forge("2.0.0-rc.1", prerelease: true, tags: { "v1" => SHA_130, "v1.3.0" => SHA_130, "v2.0.0-rc.1" => SHA_200 }, latest: "v1.3.0")

    When
    receipt = publish(gh, release_shipment("2.0.0-rc.1", SHA_200))

    Then
    writes(gh) == [["POST", "repos/{owner}/{repo}/git/refs", { "ref" => "refs/tags/v2", "sha" => SHA_200 }]]
    receipt.summary == "v2 → v2.0.0-rc.1 (#{SHA_200[0, 12]}), new; latest untouched — a pre-release is never latest"
  end

  test "a mutable release is refused before anything moves, naming the repository setting" do
    Given
    gh = forge("1.3.0", immutable: false, tags: { "v1" => SHA_120, "v1.2.0" => SHA_120, "v1.3.0" => SHA_130 }, latest: "v1.2.0")

    When
    publish(gh, release_shipment("1.3.0", SHA_130))

    Then
    error = raises(Dev::Deps::GhPublisher::MutableReleaseError)
    error.message == "deploy gh refuses v1.3.0: v1.3.0's release is mutable (immutable: false), so its tag and assets could change under " \
      "every follower of v1 — enable immutable releases on the repository " \
      "(#{Dev::Lifecycle::GithubReleases::IMMUTABLE_RELEASES_SETTING}) before the next `dev release`; a release already cut stays mutable"
    writes(gh) == []
  end

  test "a working artifact from the store is refused before the forge is asked: a head points at a release" do
    Given
    gh = FakeGh.new(root: @project)

    When
    publisher(gh).publish([store_shipment], channel:, track: Dev::Lifecycle::Track::Testing, scratch: @workspace / "scratch")

    Then
    error = raises(Dev::Deps::GhPublisher::WorkingArtifactError)
    error.message == "deploy gh received dev (0.7.13+3f2a1c9d8e7b) from the store (the testing track): a head points at a release, " \
      "never at a working artifact — cut one with `dev release <version>`, then `dev deploy gh --release <version>`"
    gh.calls.empty?
  end

  test "a release of no series — a tag that is not a version — is the series' refusal" do
    Given
    gh = forge("nightly", tags: {})

    When
    publish(gh, release_shipment("nightly", SHA_130))

    Then
    raises(Dev::Lifecycle::Series::NotAVersionError)
  end

  test "the preview reports the heads as they stand and the candidate, writing nothing: #{what}" do
    Given
    gh = forge("1.3.0", immutable:, tags:, latest:)

    When
    lines = preview(gh, release_shipment("1.3.0", SHA_130))

    Then
    lines == expected
    writes(gh) == []

    Where
    what                        | immutable | tags                                                                            | latest   | expected
    "nothing deployed yet"      | true      | { "v1.3.0" => SHA_130 }                                                         | nil      | ["Heads: none; latest none", "Candidate: v1 → v1.3.0 (#{SHA_130[0, 12]}), new; latest → v1.3.0"]
    "two series live"           | true      | { "v1" => SHA_120, "v2" => SHA_200, "v1.2.0" => SHA_120, "v2.0.0" => SHA_200 }  | "v2.0.0" | ["Heads: v1 → v1.2.0 (#{SHA_120[0, 12]}), v2 → v2.0.0 (#{SHA_200[0, 12]}); latest v2.0.0", "Candidate: v1 → v1.3.0 (#{SHA_130[0, 12]}), from v1.2.0 (#{SHA_120[0, 12]}); latest stays v2.0.0 — v2 is the newest series"]
    "a pointer at no release"   | true      | { "v1" => SHA_110 }                                                             | nil      | ["Heads: v1 → #{SHA_110[0, 12]}; latest none", "Candidate: v1 → v1.3.0 (#{SHA_130[0, 12]}), from #{SHA_110[0, 12]}; latest → v1.3.0"]
    "a mutable release"         | false     | { "v1" => SHA_120, "v1.2.0" => SHA_120 }                                        | "v1.2.0" | ["Heads: v1 → v1.2.0 (#{SHA_120[0, 12]}); latest v1.2.0", "Candidate: v1 → v1.3.0 (#{SHA_130[0, 12]}), from v1.2.0 (#{SHA_120[0, 12]}); latest → v1.3.0", "Refused: v1.3.0's release is mutable (immutable: false), so its tag and assets could change under every follower of v1 — enable immutable releases on the repository (#{Dev::Lifecycle::GithubReleases::IMMUTABLE_RELEASES_SETTING}) before the next `dev release`; a release already cut stays mutable"]
  end

  test "the preview of a working artifact is the same refusal as the deploy's" do
    When
    preview(FakeGh.new(root: @project), store_shipment)

    Then
    raises(Dev::Deps::GhPublisher::WorkingArtifactError)
  end

  test "a complete self-contained tree and a plain asset are both accepted, without the forge being asked" do
    Given
    gh = FakeGh.new(root: @project)
    plain = @workspace / "plain"
    plain.mkpath
    (plain / "dev.zip").write("zip")

    When
    publisher(gh).accept!(tool_tree(@workspace / "complete"), channel:)
    publisher(gh).accept!(plain, channel:)

    Then
    gh.calls.empty?
  end

  test "a self-contained tree selected without its lock is refused at package, naming the channel and the lock" do
    Given "the tree as a files: list leaving deps.lock out would select it"
    tree = tool_tree(@workspace / "incomplete")
    (tree / "deps.lock").delete

    When
    publisher(FakeGh.new(root: @project)).accept!(tree, channel:)

    Then
    error = raises(Dev::Deps::GhPublisher::IncompleteTreeError)
    error.message == "channel 'gh' refuses the tree as it would ship: " \
      "it ships dependencies.rb without deps.lock — a self-contained tree carries its lock beside its manifest"
  end

  test "every gap the closure reads is in the one refusal, the channel named first" do
    Given "a Gemfile with no Ruby pin, and a bin/ name an exe/ would take"
    tree = tool_tree(@workspace / "gaps", lock: FORMULA_LOCK)
    (tree / "bin").mkpath
    (tree / "bin/ai-flow").write("#!/bin/sh\n")
    gaps = Dev::Deps::ToolClosure.new(tree:).gaps

    When
    publisher(FakeGh.new(root: @project)).accept!(tree, channel:)

    Then
    error = raises(Dev::Deps::GhPublisher::IncompleteTreeError)
    gaps.size == 2
    error.message == "channel 'gh' refuses the tree as it would ship: it #{gaps.join("; it ")}"
    error.message.include?("pins no ruby in deps.lock")
    error.message.include?("carries bin/ai-flow beside exe/ai-flow")
  end

  test "the channel's head is pointed, the forge's latest designation is its to move, and the publisher declares itself by the channel's name" do
    Given
    publisher = Dev::Deps::GhPublisher.new(project_root: @project)

    Expect
    publisher.head_strategy == Dev::Lifecycle::HeadStrategy::Pointed
    publisher.owns_release_designation?
    publisher.to_s == "gh"
    Dev::Deps::GhPublisher::CHANNEL == "gh"
  end

  # A candidate over an empty forge, each member overridable.
  def candidate(version: "1.3.0", sha: SHA_130, immutable: true, latest: nil)
    Dev::Deps::GhPublisher::Candidate.new(
      tag: Dev::Lifecycle::ReleaseTag.new(version), sha:,
      facts: Dev::Lifecycle::GithubReleases::Facts.new(immutable:, prerelease: false),
      heads: Dev::Lifecycle::GithubHeads::Heads.new(pointers: [], releases: {}, latest: latest && Dev::Lifecycle::ReleaseTag.new(latest)),
    )
  end

  test "a candidate is a value: the same release over the same forge state, member for member" do
    Expect
    assert_value_semantics candidate,
      equal_to: candidate,
      unequal_to: [candidate(version: "1.2.0"), candidate(sha: SHA_120), candidate(immutable: false), candidate(latest: "1.2.0")]
  end
end
