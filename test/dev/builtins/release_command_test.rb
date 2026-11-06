# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/builtins/package_command"
require "dev/builtins/release_command"
require "dev/dispatch"
require "dev/dispatch_resolver"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/target_placement"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "stringio"
require "support/fake_gh"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real checkout with
# a bare origin (the cut pushes to it), a real build script, a real store
# in a temp data root and dev's own packagers under a real PackageCommand.
# The forge is the one boundary scripted — a FakeGh that also keeps a copy
# of what was uploaded, since the verb gathers its assets in a directory
# it removes when done.
transform!(RSpock::AST::Transformation)
class Dev::Builtins::ReleaseCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOW = Time.utc(2026, 11, 6, 12, 30, 0)
  URL = "https://github.com/d3mlabs/cellbound-3d/releases/tag/v1.2.0"

  # A FakeGh that snapshots the files of a `release upload` into a kept
  # directory before the verb's temp dir goes away.
  class SnapshottingGh < FakeGh
    attr_reader :uploads

    def initialize(uploads:, root:)
      super(root:)
      @uploads = uploads
    end

    def capture(argv, stdin: nil)
      if argv.first(2) == ["release", "upload"]
        argv[3..].reject { |word| word.start_with?("--") }.each { |file| FileUtils.cp(file, @uploads / File.basename(file)) }
      end
      super
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("release-command-"))
    @project = @root / "project"
    @origin = @root / "origin.git"
    @uploads = @root / "uploads"
    @uploads.mkpath
    @project.mkpath
    (@project / "build.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_TARGET ${DEV_PLATFORM:-} ${DEV_CONFIG:-}" > "$DEV_INSTALL/built.txt"
      echo "$DEV_TARGET" >> "#{@root}/build-runs"
    SH
    (@project / "VERSION").write("1.1.0\n")
    Open3.capture2e("git", "init", "-q", "--bare", @origin.to_s)
    git("init", "-q", "-b", "main")
    # The cut's own bump commit runs through Dev::Lifecycle::Git, which carries no identity
    # of its own — the repo must hold one, since CI runners have no global git identity.
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    git("add", ".")
    commit("one")
    git("remote", "add", "origin", @origin.to_s)
    git("push", "-q", "-u", "origin", "main")
    @out = StringIO.new
    @gh = SnapshottingGh.new(uploads: @uploads, root: @project)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @project.to_s, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end

  def commit(message) = git("commit", "-q", "--allow-empty", "-m", message)
  def head = git("rev-parse", "HEAD").strip
  def short_head = head[0, 12]
  def build_runs = (@root / "build-runs").file? ? (@root / "build-runs").readlines(chomp: true) : []
  def origin_refs = Open3.capture2("git", "-C", @origin.to_s, "for-each-ref", "--format=%(refname)").first.lines(chomp: true).sort

  def client
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d", desc: "Client", platforms: [PLATFORM::Linux64], configs: [CONFIG::Development, CONFIG::Release],
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "sh ./build.sh"),
    )
  end

  def server
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d-server", desc: "Server", platforms: [PLATFORM::Linux64],
      builder: Dev::Lifecycle::BuilderSpec::Script.new(command: "sh ./build.sh"),
    )
  end

  def targets = [client, server]
  def build(name) = Dev::Lifecycle::Build.parse(name, targets)
  def release_builds = Dev::Lifecycle::ReleaseBuilds.new(builds: [build("cellbound-3d-linux64-release"), build("cellbound-3d-server-linux64")])
  def store = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)

  def dispatcher
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    placements = targets.to_h do |target|
      host = target.platforms.to_h { |platform| [platform, Dev::Placement::Host.new] }
      [target.name, Dev::TargetPlacement.new(target: target, placements: host, host_platform: PLATFORM::Linux64)]
    end
    Dev::BuildDispatcher.new(placements: placements, resolver: Dev::DispatchResolver.new(host_rule: host_rule))
  end

  def listing = Dev::BuildListing.new(targets: targets, dispatcher: dispatcher)

  def package
    Dev::Builtins::PackageCommand.new(
      selector: Dev::BuildSelector.new(targets: targets), dispatcher: dispatcher, listing: listing,
      ports: Dev::Lifecycle::Ports.new(project_root: @project), store: store, clock: -> { NOW }, out: @out,
    )
  end

  def command(release: release_builds, store: self.store)
    Dev::Builtins::ReleaseCommand.new(
      release:, cut: Dev::Lifecycle::ReleaseCut.new(git: Dev::Lifecycle::Git.new(root: @project)), package:, store:,
      releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), listing:, clock: -> { NOW }, out: @out,
    )
  end

  def context
    Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui), project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  def execute(verb, *words)
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context)
  end

  def forge_has_no_release = @gh.refuses(["release", "view"], with: "release not found")
  def forge_creates = @gh.answers(["release", "create"], with: "#{URL}\n")
  def forge_accepts_upload = @gh.answers(["release", "upload"], with: "")

  test "a fresh cut: bumps VERSION, tags, pushes, packages each release build at the tag, creates the release and attaches the archives" do
    Given
    forge_has_no_release
    forge_creates
    forge_accepts_upload

    When
    execute(command, "1.2.0")

    Then "the bump commit is HEAD, tagged, both on origin"
    (@project / "VERSION").read == "1.2.0\n"
    git("log", "-1", "--format=%s").strip == "Bump version to 1.2.0"
    git("rev-parse", "v1.2.0^{commit}").strip == head
    origin_refs == ["refs/heads/main", "refs/tags/v1.2.0"]

    # both builds ran and their artifacts are the tag's, stamped with the bumped version
    build_runs == ["cellbound-3d", "cellbound-3d-server"]
    store.artifact(build("cellbound-3d-linux64-release")).manifest.build_id == Dev::Lifecycle::BuildId.new("1.2.0+#{short_head}")
    store.artifact(build("cellbound-3d-server-linux64")).manifest.build_id == Dev::Lifecycle::BuildId.new("1.2.0+#{short_head}")

    # the forge was asked for the release, given one with the notes, then the renamed archives and release.json
    @gh.calls.map { |call| call.argv.first(3) } ==
      [["release", "view", "v1.2.0"], ["release", "create", "v1.2.0"], ["release", "upload", "v1.2.0"]]
    @gh.calls[1].argv.include?("--verify-tag")
    @gh.calls[1].stdin == "Release v1.2.0."
    @gh.calls[2].argv.map { |word| File.basename(word) }[3..] ==
      ["cellbound-3d-linux64-release-1.2.0.zip", "cellbound-3d-server-linux64-1.2.0.zip", "release.json", "--clobber"]

    # the uploaded archives are the store's bytes; release.json names the tag, its commit and each archive with its build id
    (@uploads / "cellbound-3d-linux64-release-1.2.0.zip").read == store.artifact(build("cellbound-3d-linux64-release")).archive.read
    manifest = Dev::Lifecycle::Manifest::Release.read(@uploads, targets: targets)
    manifest.tag == "v1.2.0"
    manifest.sha == head
    manifest.archives.map(&:to_json_hash) == [
      { "build" => "cellbound-3d-linux64-release", "name" => "cellbound-3d-linux64-release-1.2.0.zip",
        "sha256" => Digest::SHA256.file((@uploads / "cellbound-3d-linux64-release-1.2.0.zip").to_s).hexdigest, "build_id" => "1.2.0+#{short_head}" },
      { "build" => "cellbound-3d-server-linux64", "name" => "cellbound-3d-server-linux64-1.2.0.zip",
        "sha256" => Digest::SHA256.file((@uploads / "cellbound-3d-server-linux64-1.2.0.zip").to_s).hexdigest, "build_id" => "1.2.0+#{short_head}" },
    ]

    # the report: the cut announced, then what was released, and that nothing was deployed
    @out.string.lines.first == "cutting v1.2.0 on main: bump VERSION 1.1.0 → 1.2.0, tag, push\n"
    @out.string.include?("released v1.2.0 (#{short_head}) → #{URL}\n")
    @out.string.include?("  cellbound-3d-linux64-release-1.2.0.zip (1.2.0+#{short_head})\n")
    @out.string.include?("  release.json\n")
    @out.string.lines.last == "nothing deployed — `dev deploy <channel> --release 1.2.0` ships it\n"
  end

  test "a retry after the forge refused resumes the cut: nothing re-cut, the artifacts current, the existing release's assets replaced" do
    Given "a first run that cut, pushed and packaged, then lost the forge"
    forge_has_no_release
    @gh.refuses(["release", "create"], with: "HTTP 502")
    begin
      execute(command, "1.2.0")
    rescue Dev::Lifecycle::GithubReleases::ApiError
      nil
    end
    tagged = head
    @out.truncate(0)
    @out.rewind
    @gh.calls.clear
    @gh.answers(["release", "view"], with: "#{URL}\n")
    forge_accepts_upload

    When
    execute(command, "1.2.0")

    Then "HEAD is the one cut; the builds were not rebuilt (current at the tag); the release found, not created; upload clobbers"
    head == tagged
    git("log", "--oneline").lines.size == 2
    build_runs == ["cellbound-3d", "cellbound-3d-server"]
    @gh.calls.map { |call| call.argv.first(2) } == [["release", "view"], ["release", "upload"]]
    @gh.calls.last.argv.last == "--clobber"
    @out.string.lines.first == "resuming v1.2.0: HEAD is already tagged — pushing, then packaging at the tag\n"
    @out.string.include?("released v1.2.0 (#{tagged[0, 12]}) → #{URL}\n")
  end

  test "a project without a VERSION file is tagged as it is, no bump" do
    Given
    git("rm", "-q", "VERSION")
    commit("no version in source")
    before = head
    forge_has_no_release
    forge_creates
    forge_accepts_upload

    When
    execute(command, "0.1.0")

    Then
    head == before
    git("rev-parse", "v0.1.0^{commit}").strip == before
    @out.string.lines.first == "cutting v0.1.0 on main: tag, push\n"
    store.artifact(build("cellbound-3d-server-linux64")).manifest.build_id ==
      Dev::Lifecycle::BuildId.new("#{Dev::Lifecycle::BuildId::DEFAULT_SEMVER}+#{before[0, 12]}")
  end

  test "release takes exactly one version: #{what}" do
    When
    execute(command, *words)

    Then
    error = raises(Dev::Builtins::ReleaseCommand::VersionArgumentError)
    error.message.include?("release takes one version")
    build_runs.empty?
    origin_refs == ["refs/heads/main"]

    Where
    what          | words
    "none"        | []
    "two"         | ["1.2.0", "1.3.0"]
  end

  test "a version that cannot name a tag is the tag's refusal, before anything moves" do
    When
    execute(command, "1.2/0")

    Then
    raises(Dev::Lifecycle::ReleaseTag::InvalidVersionError)
    origin_refs == ["refs/heads/main"]
  end

  test "a dirty tree is refused before anything moves" do
    Given
    (@project / "wip.txt").write("x")

    When
    execute(command, "1.2.0")

    Then
    raises(Dev::Lifecycle::ReleaseCut::DirtyTreeError)
    origin_refs == ["refs/heads/main"]
    build_runs.empty?
    @gh.calls.empty?
  end

  test "an artifact that is not the tag's after packaging is refused: a release attaches what was packaged here, at the tag" do
    Given "a store that answers packaging with an artifact of another commit"
    elsewhere = Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "other-data").to_s)
    stale_build = build("cellbound-3d-linux64-release")
    elsewhere.dir(stale_build).mkpath
    (elsewhere.dir(stale_build) / "cellbound-3d-linux64-release.zip").write("old")
    Dev::Lifecycle::Manifest::Artifact.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(now: NOW), build: stale_build,
      state: Dev::Lifecycle::GitState.new(sha: "000000000000", dirty: false), packaged_at: NOW, builder: "script", builder_version: nil,
      build_id: Dev::Lifecycle::BuildId.new("1.1.0+000000000000"), archive: "cellbound-3d-linux64-release.zip", archive_sha256: "x",
    ).write(elsewhere.dir(stale_build))

    When
    execute(command(store: elsewhere), "1.2.0")

    Then
    error = raises(Dev::Builtins::ReleaseCommand::ArtifactNotAtTagError)
    error.message.include?("the store holds 1.1.0+000000000000")
    @gh.calls.empty?
  end

  test "the usage lists the release builds under their own heading, each with where it runs" do
    When
    rendered = command.listing

    Then
    rendered.heading == "Release builds"
    rendered.subjects.map(&:name) == ["cellbound-3d-linux64-release", "cellbound-3d-server-linux64"]
    rendered.subjects.map(&:placement).all?(Dev::Placement::Host)
  end
end
