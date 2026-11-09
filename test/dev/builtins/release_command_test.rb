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
require "dev/enrolled_runner_lookup"
require "dev/host_environment"
require "dev/host_rule"
require "dev/lifecycle"
require "dev/lifecycle_executor"
require "dev/placement"
require "dev/remote_dispatches"
require "dev/settings"
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

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available = nil
  end

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

  # Every build is host-placed on a linux64 machine, so each `package`
  # dispatches natively: the remote side is wired as the resolver needs
  # it, over a forge nothing reaches.
  def dispatcher
    host_rule = Dev::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    placements = targets.to_h do |target|
      host = target.platforms.to_h { |platform| [platform, Dev::Placement::Host.new] }
      [target.name, Dev::TargetPlacement.new(target: target, placements: host, host_platform: PLATFORM::Linux64)]
    end
    remotes = Dev::RemoteDispatches.new(
      root: @project, ui: typed_mock(Dev::Cli::Ui), out: @out, runs: Dev::Lifecycle::WorkflowRuns.new(gh: @gh),
    )
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    resolver = Dev::DispatchResolver.new(
      host_rule: host_rule, remotes: remotes, enrolled: NoneEnrolled.new, settings: settings, inside_job: false,
    )
    Dev::BuildDispatcher.new(placements: placements, resolver: resolver)
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
      releases: Dev::Lifecycle::GithubReleases.new(gh: @gh), listing:, clock: -> { NOW },
    )
  end

  # A terminal that answers the confirm as told, remembering the question.
  class AnsweringUi < Dev::Cli::NoUi
    attr_reader :asked

    def initialize(out:, answer:)
      super(out:)
      @answer = answer
      @asked = []
    end

    def confirm(question)
      @asked << question
      @answer
    end
  end

  def context(ui: Dev::Cli::NoUi.new(out: @out))
    Dev::ExecutionContext.new(ui:, project: Dev::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  # `--yes` unless the test is about the confirm: NoUi has no terminal.
  def execute(verb, *words, ui: Dev::Cli::NoUi.new(out: @out), confirm: true)
    words = [*words, "--yes"] if confirm
    Dev::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context(ui:))
  end

  def forge_has_no_release = @gh.refuses(["release", "view"], with: "release not found")
  def forge_creates = @gh.answers(["release", "create"], with: "#{URL}\n")
  def forge_accepts_upload = @gh.answers(["release", "upload"], with: "")

  test "a fresh cut: bumps VERSION, tags, pushes, packages each release build at the tag, creates the release and attaches the archives" do
    Given
    forge_has_no_release
    forge_creates
    forge_accepts_upload

    base = head

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

    # the UI (dev#514): the plan frame with the base line, then the cut's steps, the publish's, the epilogue
    @out.string.lines.first(10).join == <<~OUT
      Release: 1.1.0 → 1.2.0
      Base: main @ #{base[0, 12]} — first release, no previous tag (in sync with origin/main)
      Notes:
        Release v1.2.0.
      Steps:
        1. Bump VERSION 1.1.0 → 1.2.0
        2. Tag v1.2.0
        3. Push main + tag v1.2.0 to origin
        4. Package cellbound-3d-linux64-release, cellbound-3d-server-linux64 at the tag
        5. Create GitHub release v1.2.0 and attach 2 archives + release.json
    OUT
    @out.string.include?("Cutting v1.2.0\n✓ Bumping VERSION 1.1.0 → 1.2.0\n✓ Tagging v1.2.0\n✓ Pushing main + tag v1.2.0 to origin\n")
    @out.string.include?("Packaging cellbound-3d-linux64-release\npackaged cellbound-3d-linux64-release → ")
    @out.string.include?("✓ Packaging cellbound-3d-linux64-release\nPackaging cellbound-3d-server-linux64\npackaged cellbound-3d-server-linux64 → ")
    @out.string.include?("✓ Packaging cellbound-3d-server-linux64\nPublishing v1.2.0\n")
    @out.string.include?("Publishing v1.2.0\n✓ Writing release.json\n✓ Creating GitHub release v1.2.0\n" \
      "✓ Attaching cellbound-3d-linux64-release-1.2.0.zip, cellbound-3d-server-linux64-1.2.0.zip, release.json\n")
    @out.string.lines.last(4).join == <<~OUT
      ✓ v1.2.0 released! (#{short_head}, from main) → #{URL}
        cellbound-3d-linux64-release-1.2.0.zip (1.2.0+#{short_head})
        cellbound-3d-server-linux64-1.2.0.zip (1.2.0+#{short_head})
      Nothing deployed — ship it: dev deploy <channel> --release 1.2.0
    OUT
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
    @out.string.lines.first(2).join == "Resuming v1.2.0\nBase: main @ #{tagged[0, 12]} — HEAD already tagged, nothing to cut (in sync with origin/main)\n"
    @out.string.include?("  1. Push main + tag v1.2.0 to origin\n  2. Package cellbound-3d-linux64-release, cellbound-3d-server-linux64 at the tag\n")
    !@out.string.include?("Bumping")
    @out.string.include?("✓ Creating GitHub release v1.2.0\n") == false
    @out.string.include?("✓ GitHub release v1.2.0 exists — attaching to it\n")
    @out.string.include?("✓ v1.2.0 released! (#{tagged[0, 12]}, from main) → #{URL}\n")
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
    @out.string.lines.first == "Release: v0.1.0\n"
    @out.string.include?("  1. Tag v0.1.0\n  2. Push main + tag v0.1.0 to origin\n")
    !@out.string.include?("Bump")
    store.artifact(build("cellbound-3d-server-linux64")).manifest.build_id ==
      Dev::Lifecycle::BuildId.new("#{Dev::Lifecycle::BuildId::DEFAULT_SEMVER}+#{before[0, 12]}")
  end

  test "the base line names the previous tag and the commits since, and the checkout's drift from origin as last fetched (dev#514)" do
    Given "a tagged previous release, two commits since, one of them unpushed"
    git("tag", "v1.1.0")
    git("push", "-q", "origin", "refs/tags/v1.1.0")
    commit("fix a")
    git("push", "-q", "origin", "main")
    commit("fix b")
    forge_has_no_release
    forge_creates
    forge_accepts_upload
    base = head

    When
    execute(command, "1.2.0")

    Then
    @out.string.lines[1] == "Base: main @ #{base[0, 12]} — 2 commits since v1.1.0 (1 ahead of origin/main, unpushed)\n"
    @out.string.lines[2..4].join == "Notes:\n  #{base[0, 7]} fix b\n  #{git("rev-parse", "HEAD~2").strip[0, 7]} fix a\n"
    @gh.calls[1].stdin == "#{base[0, 7]} fix b\n#{git("rev-parse", "HEAD~2").strip[0, 7]} fix a"
  end

  test "the confirm: without --yes the terminal is asked after the plan and a no cuts nothing; without a terminal the verb refuses and says how (dev#514): #{what}" do
    Given
    ui = AnsweringUi.new(out: @out, answer:)

    When
    execute(command, "1.2.0", ui:, confirm: false)

    Then "nothing moved; the plan was shown first"
    raises(error)
    ui.asked == ["Proceed?"]
    origin_refs == ["refs/heads/main"]
    (@project / "VERSION").read == "1.1.0\n"
    build_runs.empty?
    @out.string.lines.first == "Release: 1.1.0 → 1.2.0\n"

    Where
    what                    | answer | error
    "declined"              | false  | Dev::Builtins::ReleaseCommand::DeclinedError
    "no terminal to ask at" | nil    | Dev::Builtins::ReleaseCommand::NoTerminalError
  end

  test "a yes at the terminal is the same release as --yes" do
    Given
    forge_has_no_release
    forge_creates
    forge_accepts_upload
    ui = AnsweringUi.new(out: @out, answer: true)

    When
    execute(command, "1.2.0", ui:, confirm: false)

    Then
    ui.asked == ["Proceed?"]
    origin_refs == ["refs/heads/main", "refs/tags/v1.2.0"]
  end

  test "a step that fails closes the frame as failed and the verb stops there, the failure its own: a refused push leaves the local cut for the retry" do
    Given "an origin that refuses pushes"
    (@origin / "hooks").mkpath
    (@origin / "hooks" / "pre-receive").write("#!/bin/sh\necho no >&2\nexit 1\n")
    (@origin / "hooks" / "pre-receive").chmod(0o755)

    When
    execute(command, "1.2.0")

    Then
    raises(Dev::Lifecycle::Git::CommandFailedError)
    @out.string.include?("✓ Tagging v1.2.0\n✗ Pushing main + tag v1.2.0 to origin\n")
    git("rev-parse", "v1.2.0^{commit}").strip == head
    build_runs.empty?
    @gh.calls.empty?
  end

  test "the flags: --yes skips the confirm" do
    Expect
    command.flags.map(&:name) == ["--yes"]
  end

  test "no version, or a bump word, releases the next version of the one in source — #{what}: 1.1.0 → #{expected} (dev#525)" do
    Given
    forge_has_no_release
    forge_creates
    forge_accepts_upload

    When
    execute(command, *words)

    Then "the plan said which version the bump picked, before the confirm; the cut is that version"
    @out.string.lines.first == "Release: 1.1.0 → #{expected}\n"
    (@project / "VERSION").read == "#{expected}\n"
    origin_refs == ["refs/heads/main", "refs/tags/v#{expected}"]
    @gh.calls[1].argv.first(3) == ["release", "create", "v#{expected}"]

    Where
    what                 | words     | expected
    "nothing: the patch" | []        | "1.1.1"
    "patch"              | ["patch"] | "1.1.1"
    "minor"              | ["minor"] | "1.2.0"
    "major"              | ["major"] | "2.0.0"
  end

  test "a bump of a project that keeps no version in source is refused, naming the fix, before anything moves" do
    Given
    git("rm", "-q", "VERSION")
    commit("no version in source")

    When
    execute(command, "minor")

    Then
    error = raises(Dev::Builtins::ReleaseCommand::VersionArgumentError)
    error.message == "release has no VERSION to bump from — give the version (`dev release 1.2.0`)"
    origin_refs == ["refs/heads/main"]
    build_runs.empty?
  end

  test "a bump of a VERSION that is not major.minor.patch is the version's refusal, before anything moves" do
    Given
    (@project / "VERSION").write("3.0.0-rc.1\n")
    git("add", "VERSION")
    commit("rc")

    When
    execute(command)

    Then
    raises(Dev::Lifecycle::ProjectVersion::NotSemverError)
    origin_refs == ["refs/heads/main"]
  end

  test "release takes at most one word — a version or a bump — got two" do
    When
    execute(command, "1.2.0", "1.3.0")

    Then
    error = raises(Dev::Builtins::ReleaseCommand::VersionArgumentError)
    error.message == "release takes one version or bump (`dev release`, `dev release 1.2.0`, `dev release minor`), got \"1.2.0\", \"1.3.0\""
    build_runs.empty?
    origin_refs == ["refs/heads/main"]
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
