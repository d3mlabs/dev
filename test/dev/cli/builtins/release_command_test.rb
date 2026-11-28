# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/build_dispatcher"
require "dev/cli/build_listing"
require "dev/cli/build_selector"
require "dev/cli/builtins/package_command"
require "dev/cli/builtins/release_command"
require "dev/cli/dispatch"
require "dev/cli/dispatch_resolver"
require "dev/enrolled_runner_lookup"
require "dev/host_environment"
require "dev/cli/host_rule"
require "dev/lifecycle"
require "dev/cli/lifecycle_executor"
require "dev/cli/placement"
require "dev/cli/remote_dispatches"
require "dev/settings"
require "dev/cli/target_placement"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "stringio"
require "support/answering_ui"
require "support/release_forge_gh"
require "time"
require "tmpdir"

# The verb end to end through the LifecycleExecutor: a real checkout with
# a bare origin (the cut pushes to it), a real build script, a real store
# in a temp data root and dev's own packagers under a real PackageCommand,
# run per build with `--attach`. The forge is the one boundary scripted —
# a ReleaseForgeGh that keeps what each attach uploads and lists it back,
# since the release reads its own facts from the forge, not from the
# store.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::ReleaseCommandTest < Minitest::Test
  include SorbetHelper

  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config
  NOW = Time.utc(2026, 11, 6, 12, 30, 0)
  URL = "https://github.com/d3mlabs/cellbound-3d/releases/tag/v1.2.0"
  FACTS_PATH = "repos/{owner}/{repo}/releases/tags/v1.2.0"

  # The repo has no enrolled runner online.
  class NoneEnrolled < Dev::EnrolledRunnerLookup
    def available
      nil
    end
  end

  # Stands in for `package --attach` run elsewhere: instead of packaging,
  # it leaves on the forge whatever the test says a host left — nothing,
  # a stale entry — so the release's read-back is exercised on its own.
  class LeavingExecutor < Dev::Cli::LifecycleExecutor
    def initialize(&leave)
      super()
      @leave = leave
    end

    def execute(verb, args:, context:)
      @leave.call(args)
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("release-command-"))
    @project = @root / "project"
    @origin = @root / "origin.git"
    @project.mkpath
    (@project / "build.sh").write(<<~SH)
      #!/bin/sh
      set -eu
      echo "$DEV_TARGET ${DEV_PLATFORM:-} ${DEV_CONFIG:-}" > "$DEV_STAGE/built.txt"
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
    @gh = ReleaseForgeGh.new(root: @project)
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

  def commit(message)
    git("commit", "-q", "--allow-empty", "-m", message)
  end

  def head
    git("rev-parse", "HEAD").strip
  end

  def short_head
    head[0, 12]
  end

  def build_runs
    (@root / "build-runs").file? ? (@root / "build-runs").readlines(chomp: true) : []
  end

  def origin_refs
    Open3.capture2("git", "-C", @origin.to_s, "for-each-ref", "--format=%(refname)").first.lines(chomp: true).sort
  end

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

  def targets
    [client, server]
  end

  def build(name)
    Dev::Lifecycle::Build.parse(name, targets)
  end

  def release_builds
    Dev::Lifecycle::ReleaseBuilds.new(builds: [build("cellbound-3d-linux64-release"), build("cellbound-3d-server-linux64")])
  end

  def store
    Dev::Lifecycle::Store.new(project_name: "cellbound-3d", targets: targets, data_root: (@root / "data").to_s)
  end

  # Every build is host-placed on a linux64 machine, so each `package`
  # dispatches natively: the remote side is wired as the resolver needs
  # it, over a forge nothing reaches.
  def dispatcher
    host_rule = Dev::Cli::HostRule.new(host_environment: Dev::HostEnvironment.new(path: (@root / "no-marker").to_s), inside_container: false)
    placements = targets.to_h do |target|
      host = target.platforms.to_h { |platform| [platform, Dev::Cli::Placement::Host.new] }
      [target.name, Dev::Cli::TargetPlacement.new(target: target, placements: host, host_platform: PLATFORM::Linux64)]
    end
    remotes = Dev::Cli::RemoteDispatches.new(
      root: @project, ui: typed_mock(Dev::Ui), out: @out, runs: Dev::Lifecycle::WorkflowRuns.new(gh: @gh),
    )
    settings = Dev::Settings.new(config_path: (@root / "config.yml").to_s, system_config_path: (@root / "none.yml").to_s)
    resolver = Dev::Cli::DispatchResolver.new(
      host_rule: host_rule, remotes: remotes, enrolled: NoneEnrolled.new, settings: settings,
    )
    Dev::Cli::BuildDispatcher.new(placements: placements, resolver: resolver)
  end

  def listing
    Dev::Cli::BuildListing.new(targets: targets, dispatcher: dispatcher)
  end

  def releases
    Dev::Lifecycle::GithubReleases.new(gh: @gh)
  end

  def ledger
    Dev::Lifecycle::ReleaseLedger.new(releases:, targets:, clock: -> { NOW })
  end

  def package
    Dev::Cli::Builtins::PackageCommand.new(
      selector: Dev::Cli::BuildSelector.new(targets: targets), dispatcher: dispatcher, listing: listing,
      ports: Dev::Lifecycle::Ports.new(project_root: @project), store: store, clock: -> { NOW }, out: @out,
      attachment: Dev::Lifecycle::ReleaseAttachment.new(releases:, ledger:),
    )
  end

  def command(release: release_builds, designates_latest: true, executor: Dev::Cli::LifecycleExecutor.new)
    Dev::Cli::Builtins::ReleaseCommand.new(
      release:, cut: Dev::Lifecycle::ReleaseCut.new(git: Dev::Lifecycle::Git.new(root: @project)), package:,
      releases:, ledger:, listing:, designates_latest:, executor:,
    )
  end

  def context(ui: Dev::NoUi.new(out: @out))
    Dev::Cli::ExecutionContext.new(ui:, project: Dev::Cli::ProjectContext.new(name: "cellbound-3d", root: @project))
  end

  # `--yes` unless the test is about the confirm: NoUi has no terminal.
  def execute(verb, *words, ui: Dev::NoUi.new(out: @out), confirm: true)
    words = [*words, "--yes"] if confirm
    Dev::Cli::LifecycleExecutor.new.execute(verb, args: parsed_args(verb, words), context: context(ui:))
  end

  def forge_has_no_release
    @gh.refuses(["release", "view"], with: "release not found")
  end

  def forge_creates
    @gh.answers(["release", "create"], with: "#{URL}\n")
  end

  def forge_publishes
    @gh.answers(["release", "edit"], with: "#{URL}\n")
  end

  # The forge holds a release for the tag: a draft a failed run left, or
  # one already published. Answered once per asker: the cut's own lookup,
  # then each `package --attach`'s guard.
  def forge_has_release(draft:, times: 1)
    times.times { @gh.answers(["release", "view"], with: { "url" => URL, "isDraft" => draft }) }
  end

  # The release as the forge holds it once cut: frozen, on a repo with
  # immutable releases on, unless a test is about the warning.
  def forge_reports(tag, immutable: true)
    @gh.answers(["api", "repos/{owner}/{repo}/releases/tags/#{tag}"], with: { "immutable" => immutable, "prerelease" => false })
  end

  # A fresh cut's forge: no release, a draft created, each of the two
  # release builds attaching to it, the publish, the facts.
  def forge_for_fresh_cut(tag = "v1.2.0", immutable: true)
    forge_has_no_release
    forge_creates
    forge_has_release(draft: true, times: 2)
    forge_publishes
    forge_reports(tag, immutable:)
  end

  # What the verb asked the forge, one word per call, uploads by name:
  # the protocol in the order it ran.
  def forge_log
    @gh.calls.map do |call|
      argv = call.argv
      case argv.first(2)
      when ["release", "view"] then argv[3..4] == ["--json", "assets"] ? "assets" : "find"
      when ["release", "create"] then "create"
      when ["release", "upload"] then "upload #{argv[3..].reject { |word| word.start_with?("--") }.map { |file| File.basename(file) }.join(" ")}"
      when ["release", "download"] then "download"
      when ["release", "edit"] then "publish"
      else "facts"
      end
    end
  end

  # One attach as `package --attach` leaves it: the archive uploaded, the entry recorded.
  ATTACH = ["upload %s", "assets", "download", "upload release.json"].freeze
  # The first attach finds no release.json to read back.
  FIRST_ATTACH = ["upload %s", "assets", "upload release.json"].freeze
  # The publish: the ledger read back, completed, the draft published, the facts read.
  PUBLISH = ["assets", "download", "assets", "upload release.json", "publish", "facts"].freeze

  def attach_log(archive, first: false)
    (first ? FIRST_ATTACH : ATTACH).map { |step| format(step, archive) }
  end

  def ledger_on_forge(tag)
    Dev::Lifecycle::Manifest::Release.from_json_hash(JSON.parse(@gh.attached(tag).fetch("release.json")), targets:)
  end

  def gh_call(verb)
    @gh.calls.find { |call| call.argv.first(2) == ["release", verb] }
  end

  test "a fresh cut: bumps VERSION, tags, pushes, drafts the release, packages each release build at the tag and attaches it from there, publishes" do
    Given
    forge_for_fresh_cut
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

    # the forge: asked for the release, given a draft with the notes; then each attach — the guard's lookup,
    # the archive, the ledger read and recorded; then the publish, the ledger completed before the draft
    # is published so the asset list a repository with immutable releases freezes is the complete one (dev#679)
    forge_log == ["find", "create", "find", *attach_log("cellbound-3d-linux64-release-1.2.0.zip", first: true),
                  "find", *attach_log("cellbound-3d-server-linux64-1.2.0.zip"), *PUBLISH]
    gh_call("create").argv.include?("--verify-tag")
    gh_call("create").argv.include?("--draft")
    gh_call("create").stdin == "Release v1.2.0."
    gh_call("edit").argv == ["release", "edit", "v1.2.0", "--draft=false"]
    gh_call("upload").argv.last == "--clobber"

    # the release's assets are the store's bytes; release.json names the tag, its commit and each archive with its build id
    @gh.attached("v1.2.0").keys.sort == ["cellbound-3d-linux64-release-1.2.0.zip", "cellbound-3d-server-linux64-1.2.0.zip", "release.json"]
    @gh.attached("v1.2.0").fetch("cellbound-3d-linux64-release-1.2.0.zip") == store.artifact(build("cellbound-3d-linux64-release")).archive.binread
    manifest = ledger_on_forge("v1.2.0")
    manifest.tag == "v1.2.0"
    manifest.sha == head
    manifest.archives.map(&:to_json_hash) == [
      { "build" => "cellbound-3d-linux64-release", "name" => "cellbound-3d-linux64-release-1.2.0.zip",
        "sha256" => Digest::SHA256.hexdigest(@gh.attached("v1.2.0").fetch("cellbound-3d-linux64-release-1.2.0.zip")), "build_id" => "1.2.0+#{short_head}" },
      { "build" => "cellbound-3d-server-linux64", "name" => "cellbound-3d-server-linux64-1.2.0.zip",
        "sha256" => Digest::SHA256.hexdigest(@gh.attached("v1.2.0").fetch("cellbound-3d-server-linux64-1.2.0.zip")), "build_id" => "1.2.0+#{short_head}" },
    ]

    # the UI (dev#514): the plan frame with the base line, then the cut's steps, the publish's, the epilogue
    @out.string.lines.first(11).join == <<~OUT
      Release: 1.1.0 → 1.2.0
      Base: main @ #{base[0, 12]} — first release, no previous tag (in sync with origin/main)
      Notes:
        Release v1.2.0.
      Steps:
        1. Bump VERSION 1.1.0 → 1.2.0
        2. Tag v1.2.0
        3. Push main + tag v1.2.0 to origin
        4. Create GitHub release v1.2.0 as a draft
        5. Package cellbound-3d-linux64-release, cellbound-3d-server-linux64 at the tag and attach, each from the host that packages it
        6. Publish GitHub release v1.2.0 with release.json
    OUT
    @out.string.include?("Cutting v1.2.0\n✓ Bumping VERSION 1.1.0 → 1.2.0\n✓ Tagging v1.2.0\n✓ Pushing main + tag v1.2.0 to origin\n" \
      "✓ Creating GitHub release v1.2.0\nPackaging cellbound-3d-linux64-release and attaching to v1.2.0\npackaged cellbound-3d-linux64-release → ")
    @out.string.include?("attached cellbound-3d-linux64-release-1.2.0.zip to v1.2.0's release (1.2.0+#{short_head})\n" \
      "✓ Packaging cellbound-3d-linux64-release and attaching to v1.2.0\nPackaging cellbound-3d-server-linux64 and attaching to v1.2.0\n")
    @out.string.include?("✓ Packaging cellbound-3d-server-linux64 and attaching to v1.2.0\nPublishing v1.2.0\n" \
      "✓ Reading release.json from v1.2.0's release\n✓ Writing release.json\n✓ Publishing GitHub release v1.2.0\n")
    @out.string.lines.last(4).join == <<~OUT
      ✓ v1.2.0 released! (#{short_head}, from main) → #{URL}
        cellbound-3d-linux64-release-1.2.0.zip (1.2.0+#{short_head})
        cellbound-3d-server-linux64-1.2.0.zip (1.2.0+#{short_head})
      Nothing deployed — ship it: dev deploy <channel> --release 1.2.0
    OUT
    !@out.string.include?("mutable")
  end

  test "a project with a gh channel cuts its release as not latest — `deploy gh` designates it — and the plan says so (dev#655)" do
    Given
    forge_for_fresh_cut

    When
    execute(command(designates_latest: false), "1.2.0")

    Then "the designation is withheld where the release is published — the draft's publish — not at its creation"
    gh_call("edit").argv == ["release", "edit", "v1.2.0", "--draft=false", "--latest=false"]
    @out.string.include?("  6. Publish GitHub release v1.2.0 with release.json (not latest: `deploy gh` designates it)\n")
    @out.string.lines.last == "Nothing deployed — ship it: dev deploy <channel> --release 1.2.0\n"
  end

  test "a release the forge reports mutable is warned about, naming the repository setting, before the deploy hint: no head may point at it (dev#655)" do
    Given
    forge_for_fresh_cut(immutable: false)

    When
    execute(command, "1.2.0")

    Then "released all the same; the warning is the epilogue's last line but the hint"
    origin_refs == ["refs/heads/main", "refs/tags/v1.2.0"]
    @out.string.lines.last(2).join == <<~OUT
      #{CLI::UI::Glyph::WARNING.char} v1.2.0's release is mutable: its tag and assets can still change, so no head may point at it — enable immutable releases on the repository (#{Dev::Lifecycle::GithubReleases::IMMUTABLE_RELEASES_SETTING}) before the next release
      Nothing deployed — ship it: dev deploy <channel> --release 1.2.0
    OUT
  end

  test "a retry after the forge refused the draft resumes the cut: nothing re-cut, nothing was packaged before the draft, the release goes on from there" do
    Given "a first run that cut and pushed, then lost the forge on the draft"
    forge_has_no_release
    @gh.refuses(["release", "create"], with: "HTTP 502")
    begin
      execute(command, "1.2.0")
    rescue Dev::Lifecycle::GithubReleases::ApiError
      nil
    end
    tagged = head
    runs_before = build_runs
    @out.truncate(0)
    @out.rewind
    @gh.calls.clear
    forge_for_fresh_cut

    When
    execute(command, "1.2.0")

    Then "HEAD is the one cut; the builds packaged at it now; the draft created, attached to, published"
    runs_before.empty?
    head == tagged
    git("log", "--oneline").lines.size == 2
    build_runs == ["cellbound-3d", "cellbound-3d-server"]
    forge_log.first(2) == ["find", "create"]
    forge_log.last(2) == ["publish", "facts"]
    @out.string.lines.first(2).join == "Resuming v1.2.0\nBase: main @ #{tagged[0, 12]} — HEAD already tagged, nothing to cut (in sync with origin/main)\n"
    @out.string.include?("  1. Push main + tag v1.2.0 to origin\n  2. Create GitHub release v1.2.0 as a draft\n")
    !@out.string.include?("Bumping")
    @out.string.include?("✓ v1.2.0 released! (#{tagged[0, 12]}, from main) → #{URL}\n")
  end

  test "a retry that finds the draft a failed run left attaches to it — the build already attached is not rebuilt, its upload clobbered — and publishes it (dev#679)" do
    Given "a first run that drafted and attached the first build, then lost the forge before the second"
    forge_has_no_release
    forge_creates
    forge_has_release(draft: true)
    @gh.refuses(["release", "view"], with: "HTTP 502")
    begin
      execute(command, "1.2.0")
    rescue Dev::Lifecycle::GithubReleases::ApiError
      nil
    end
    runs_before = build_runs
    attached_before = @gh.attached("v1.2.0").keys.sort
    @out.truncate(0)
    @out.rewind
    @gh.calls.clear
    forge_has_release(draft: true, times: 3)
    forge_publishes
    forge_reports("v1.2.0")

    When
    execute(command, "1.2.0")

    Then "found, each build attached (the first current at the tag, so not rebuilt), the ledger complete, published"
    runs_before == ["cellbound-3d"]
    attached_before == ["cellbound-3d-linux64-release-1.2.0.zip", "release.json"]
    build_runs == ["cellbound-3d", "cellbound-3d-server"]
    forge_log == ["find", "find", *attach_log("cellbound-3d-linux64-release-1.2.0.zip"),
                  "find", *attach_log("cellbound-3d-server-linux64-1.2.0.zip"), *PUBLISH]
    ledger_on_forge("v1.2.0").archives.map(&:build) == release_builds.builds
    @out.string.include?("✓ GitHub release v1.2.0 exists as a draft — attaching to it and publishing\n")
    @out.string.include?("✓ v1.2.0 released!")
  end

  test "a retry onto a release already published on a mutable repository attaches onto it: nothing to publish" do
    Given "the cut landed, the release published without its assets"
    forge_has_no_release
    @gh.refuses(["release", "create"], with: "HTTP 502")
    begin
      execute(command, "1.2.0")
    rescue Dev::Lifecycle::GithubReleases::ApiError
      nil
    end
    @out.truncate(0)
    @out.rewind
    @gh.calls.clear
    forge_has_release(draft: false, times: 3)
    forge_reports("v1.2.0")

    When
    execute(command, "1.2.0")

    Then "the publish's protocol minus the publish"
    forge_log.first(2) == ["find", "find"]
    forge_log.last(5) == ["assets", "download", "assets", "upload release.json", "facts"]
    gh_call("edit").nil?
    @out.string.include?("✓ GitHub release v1.2.0 exists — attaching to it\n")
    @out.string.include?("✓ v1.2.0 released! (#{short_head}, from main) → #{URL}\n")
  end

  test "a retry onto a release already published and frozen fails with the fact and the remedy: the assets cannot be completed (dev#679)" do
    Given "the release published before its assets were on — the v0.9.0 shape"
    forge_has_no_release
    @gh.refuses(["release", "create"], with: "HTTP 502")
    begin
      execute(command, "1.2.0")
    rescue Dev::Lifecycle::GithubReleases::ApiError
      nil
    end
    @gh.calls.clear
    forge_has_release(draft: false, times: 2)
    @gh.refuses(["release", "upload"], with: "HTTP 422: Cannot upload assets to an immutable release.")

    When
    execute(command, "1.2.0")

    Then
    error = raises(Dev::Lifecycle::GithubReleases::FrozenError)
    error.message.include?("v1.2.0 is published and immutable")
    error.message.include?("release the next version")
  end

  test "a project without a VERSION file is tagged as it is, no bump" do
    Given
    git("rm", "-q", "VERSION")
    commit("no version in source")
    before = head
    forge_for_fresh_cut("v0.1.0")

    When
    execute(command, "0.1.0")

    Then
    head == before
    git("rev-parse", "v0.1.0^{commit}").strip == before
    @out.string.lines.first == "Release: v0.1.0\n"
    @out.string.include?("  1. Tag v0.1.0\n  2. Push main + tag v0.1.0 to origin\n")
    !@out.string.include?("Bump")
    ledger_on_forge("v0.1.0").archives.map(&:build_id).uniq ==
      [Dev::Lifecycle::BuildId.new("#{Dev::Lifecycle::BuildId::DEFAULT_SEMVER}+#{before[0, 12]}")]
  end

  test "the base line names the previous tag and the commits since, and the checkout's drift from origin as last fetched (dev#514)" do
    Given "a tagged previous release, two commits since, one of them unpushed"
    git("tag", "v1.1.0")
    git("push", "-q", "origin", "refs/tags/v1.1.0")
    commit("fix a")
    git("push", "-q", "origin", "main")
    commit("fix b")
    forge_for_fresh_cut
    base = head

    When
    execute(command, "1.2.0")

    Then
    @out.string.lines[1] == "Base: main @ #{base[0, 12]} — 2 commits since v1.1.0 (1 ahead of origin/main, unpushed)\n"
    @out.string.lines[2..4].join == "Notes:\n  #{base[0, 7]} fix b\n  #{git("rev-parse", "HEAD~2").strip[0, 7]} fix a\n"
    gh_call("create").stdin == "#{base[0, 7]} fix b\n#{git("rev-parse", "HEAD~2").strip[0, 7]} fix a"
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
    "declined"              | false  | Dev::Cli::Builtins::ReleaseCommand::DeclinedError
    "no terminal to ask at" | nil    | Dev::Cli::Builtins::ReleaseCommand::NoTerminalError
  end

  test "a yes at the terminal is the same release as --yes" do
    Given
    forge_for_fresh_cut
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
    forge_for_fresh_cut("v#{expected}")

    When
    execute(command, *words)

    Then "the plan said which version the bump picked, before the confirm; the cut is that version"
    @out.string.lines.first == "Release: 1.1.0 → #{expected}\n"
    (@project / "VERSION").read == "#{expected}\n"
    origin_refs == ["refs/heads/main", "refs/tags/v#{expected}"]
    gh_call("create").argv.first(3) == ["release", "create", "v#{expected}"]

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
    error = raises(Dev::Cli::Builtins::ReleaseCommand::VersionArgumentError)
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
    error = raises(Dev::Cli::Builtins::ReleaseCommand::VersionArgumentError)
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

  test "what the hosts left on the draft is verified before publishing — #{what}: the draft stays, nothing published (dev#744)" do
    Given "a `package --attach` that ran elsewhere and left the draft as described"
    forge_has_no_release
    forge_creates
    tag = Dev::Lifecycle::ReleaseTag.new("1.2.0")
    left = LeavingExecutor.new do |args|
      next unless records && args.positionals == ["cellbound-3d-linux64-release"]

      entry = Dev::Lifecycle::Manifest::Release::Archive.new(
        build: build("cellbound-3d-linux64-release"), name: "cellbound-3d-linux64-release-1.2.0.zip", sha256: "x",
        build_id: Dev::Lifecycle::BuildId.new("1.2.0+#{short_head}"),
      )
      ledger.record(tag, entry, sha: head)
    end

    When
    execute(command(executor: left), "1.2.0")

    Then
    error = raises(Dev::Cli::Builtins::ReleaseCommand::NotAttachedError)
    error.message.include?(said)
    gh_call("edit").nil?
    build_runs.empty?

    Where
    what                                         | records | said
    "a build with no entry on release.json"      | false   | "it has no entry on release.json"
    "an entry whose asset is not on the release" | true    | "cellbound-3d-linux64-release-1.2.0.zip is on release.json but not among the release's assets"
  end

  test "an entry attached from another tree than the tag's is refused before publishing: a release attaches what was packaged at its tag (dev#744)" do
    Given "a host that attached the build from a stale tree"
    forge_has_no_release
    forge_creates
    tag = Dev::Lifecycle::ReleaseTag.new("1.2.0")
    left = LeavingExecutor.new do |args|
      name = "#{args.positionals.first}-1.2.0.zip"
      Dir.mktmpdir do |dir|
        archive = Pathname(dir) / name
        archive.write("old")
        releases.upload(tag, [archive])
      end
      entry = Dev::Lifecycle::Manifest::Release::Archive.new(
        build: build(args.positionals.first), name:, sha256: "x", build_id: Dev::Lifecycle::BuildId.new("1.1.0+000000000000"),
      )
      ledger.record(tag, entry, sha: "0" * 40)
    end

    When
    execute(command(executor: left), "1.2.0")

    Then
    error = raises(Dev::Cli::Builtins::ReleaseCommand::ArtifactNotAtTagError)
    error.message.include?("cellbound-3d-linux64-release attached to v1.2.0 as 1.1.0+000000000000, not from a clean tree at #{short_head}")
    gh_call("edit").nil?
  end

  test "the usage lists the release builds under their own heading, each with where it runs" do
    When
    rendered = command.listing

    Then
    rendered.heading == "Release builds"
    rendered.subjects.map(&:name) == ["cellbound-3d-linux64-release", "cellbound-3d-server-linux64"]
    rendered.subjects.map(&:placement).all?(Dev::Cli::Placement::Host)
  end
end
