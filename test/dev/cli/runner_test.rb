# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/cli/runner"
require "support/fake_gh"
require "support/recording_publisher"
require "digest"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tempfile"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class RunnerTest < Minitest::Test
  extend T::Sig
  include SorbetHelper

  # The composition root builds every builtin on its platform defaults
  # (`for_host`): the same Mac for every test here, pinned, so the catalog
  # and the usage read the same on a laptop, the box and hosted CI.
  def setup
    super
    @host_probes = pin_host_platform(os: "darwin")
  end

  test "run with empty argv prints usage" do
    Given "a Runner with a dev.yml"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Setup" } }, out: out)

    When "we run with empty argv"
    runner.run([])

    Then "the root's usage is printed: the tool's invocation, the project's name, its commands, the help hint"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Development commands for testproject")
    out.string.include?("up")
    out.string.include?("Setup")
    out.string.lines.last == "Run 'dev help <command>' for a command's usage.\n"
  end

  test "run with --help prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with --help"
    runner.run(["--help"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "run with -h prints usage" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run with -h"
    runner.run(["-h"])

    Then "usage is printed"
    out.string.include?("Usage: dev <command> [args...]")
  end

  test "help is a command: dev help prints usage and lists itself" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(out: out)

    When "we run the help command by name"
    runner.run(["help"])

    Then "usage is printed with help in the development flow section"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("help")
    out.string.include?("Show this usage")
  end

  test "usage renders the grouped sections" do
    Given "a Runner with a project command"
    out = StringIO.new
    runner = build_runner(commands: { "test" => { "run" => "rspec", "desc" => "Run tests" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the three sections render in order"
    lines = out.string.lines.map(&:chomp)
    lines.index("Project commands:") < lines.index("Environment:")
    lines.index("Environment:") < lines.index("Development flow:")
  end

  test "#{argv.inspect} prints the same root usage as bare dev" do
    Given "two Runners over the same dev.yml"
    commands = { "test" => { "run" => "rspec", "desc" => "Run tests" } }
    bare_out = StringIO.new
    out = StringIO.new

    When "running bare and with the spelling"
    build_runner(commands: commands, out: bare_out).run([])
    build_runner(commands: commands, out: out).run(argv)

    Then "one rendering"
    out.string == bare_out.string
    out.string.include?("  test         Run tests")

    Where
    argv
    ["--help"]
    ["-h"]
    ["help"]
  end

  # --- -h/--help at every node, unknown flags refused (#217) ----------------

  test "#{argv.inspect} prints the same usage as `dev help #{path.join(" ")}`: the help flag works at #{shape}" do
    Given "two Runners over the same dev.yml"
    commands = { "test" => { "run" => "rspec", "desc" => "Run tests" } }
    help_out = StringIO.new
    out = StringIO.new

    When "asking by the help command and by the flag"
    build_runner(commands: commands, out: help_out).run(["help", *path])
    build_runner(commands: commands, out: out).run(argv)

    Then "one rendering, of that node"
    out.string == help_out.string
    out.string.include?(usage_line)

    Where
    shape                         | path             | argv                                      | usage_line
    "the root"                    | []               | ["--help"]                                | "Usage: dev <command> [args...]"
    "a builtin group"             | ["deps"]         | ["deps", "--help"]                        | "Usage: dev deps <command> [args...]"
    "a builtin group, short"      | ["deps"]         | ["deps", "-h"]                            | "Usage: dev deps <command> [args...]"
    "a builtin leaf"              | ["deps", "path"] | ["deps", "path", "--help"]                | "Usage: dev deps path [args...]"
    "a leaf, after a positional"  | ["deps", "path"] | ["deps", "path", "xcode", "-h"]           | "Usage: dev deps path [args...]"
    "a flagged leaf, among flags" | ["cache", "gc"]  | ["cache", "gc", "--keep", "3", "-h"]      | "Usage: dev cache gc [args...]"
    "a global leaf in the tree"   | ["plan", "new"]  | ["plan", "new", "Carve system", "--help"] | "Usage: dev plan new [args...]"
    "the help command itself"     | ["help"]         | ["help", "--help"]                        | "Usage: dev help [args...]"
  end

  test "#{argv.inspect} is a usage error at #{shape}: the flag, the node's usage on stderr, exit 2" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(2).once

    When "running with a flag the node does not declare"
    runner.run(argv)

    Then "stderr names the flag and the node, then prints its usage; stdout stays empty"
    $stderr.string.lines.first == "dev: unknown flag '#{flag}' for '#{invocation}'\n"
    $stderr.string.include?(usage_line)
    out.string.empty?

    Cleanup
    $stderr = old_stderr

    Where
    shape                     | argv                                 | flag      | invocation      | usage_line
    "the root"                | ["--bogus"]                          | "--bogus" | "dev"           | "Usage: dev <command> [args...]"
    "a builtin group"         | ["deps", "--hlep"]                   | "--hlep"  | "dev deps"      | "Usage: dev deps <command> [args...]"
    "a builtin without flags" | ["deps", "path", "xcode", "-x"]      | "-x"      | "dev deps path" | "Usage: dev deps path [args...]"
    "a builtin with flags"    | ["cache", "gc", "--keep=3", "--kep"] | "--kep"   | "dev cache gc"  | "Usage: dev cache gc [args...]"
    "a global leaf"           | ["plan", "new", "x", "--hlep"]       | "--hlep"  | "dev plan new"  | "Usage: dev plan new [args...]"
  end

  test "run with unknown command prints error to stderr and exits 1" do
    Given "a Runner"
    runner = build_runner
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run an unknown command"
    runner.run(["nonexistent"])

    Then "error mentions the command name"
    $stderr.string.include?("nonexistent")
    $stderr.string.include?("dev --help")

    Cleanup
    $stderr = old_stderr
  end

  test "usage lists the deps group in Environment, not the retired flat dependency verbs" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "deps is one row; update-deps / install-deps / check are gone"
    out.string.include?("  deps …       Manage dependencies (update | install | check | path)")
    !out.string.include?("update-deps")
    !out.string.include?("install-deps")
    !out.string.match?(/^  check /)
  end

  test "the retired flat dependency verbs are not found" do
    Given "a Runner"
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).times(3)

    When "running each flat name"
    runner.run(["update-deps"])
    runner.run(["install-deps"])
    runner.run(["check"])

    Then "each falls through to the not-found error"
    $stderr.string.include?("Command 'update-deps' not found")
    $stderr.string.include?("Command 'install-deps' not found")
    $stderr.string.include?("Command 'check' not found")

    Cleanup
    $stderr = old_stderr
  end

  test "usage includes both built-in and project commands" do
    Given "a Runner with project commands"
    out = StringIO.new
    runner = build_runner(commands: {
      "test" => { "run" => "rspec", "desc" => "Run tests" },
      "up" => { "run" => "./bin/up.rb", "desc" => "Setup" },
    }, out: out)

    When "we print usage"
    runner.run([])

    Then "all commands appear"
    out.string.include?("deps …")
    out.string.include?("test")
    out.string.include?("up")
  end

  test "up is a builtin even when the project defines no up command" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "up is listed as the builtin dependency install"
    out.string.include?("up")
    out.string.include?("Install locked deps and bring the build container up")
  end

  test "a project up command keeps the builtin slot's section with its own desc" do
    Given "a Runner whose dev.yml overrides up"
    out = StringIO.new
    runner = build_runner(commands: { "up" => { "run" => "./bin/up.rb", "desc" => "Project setup" } }, out: out)

    When "we print usage"
    runner.run([])

    Then "the override's description wins"
    out.string.include?("Project setup")
    !out.string.include?("Install locked deps and bring the build container up")
  end

  test "usage includes the cd builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "cd is listed"
    out.string.include?("cd")
    out.string.include?("Jump to a checkout")
  end

  test "usage includes the clone builtin" do
    Given "a Runner with no project commands"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage"
    runner.run([])

    Then "clone is listed"
    out.string.include?("clone")
    out.string.include?("Clone a GitHub repo")
  end

  test "the container group is registered with every verb when the lock pins an image" do
    Given "a Runner over a checkout whose lock pins an image"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out, root: pinned_root("myapp-linux"))

    When "we print usage, then the group's usage"
    runner.run([])
    top = out.string.dup
    out.truncate(0)
    out.rewind
    runner.run(["container"])

    Then "the noun is listed at the top and its five verbs inside"
    top.include?("container")
    %w[up down reset status].all? { |verb| out.string.lines.any? { |l| l.strip.start_with?(verb) } }
  end

  test "the container group is registered when the lock pins an image, with no build block at all (dev#307)" do
    Given "a Runner over a checkout whose lock pins two images"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out, root: pinned_root("snappy-linux", "snappy-server"))
    Dev::ContainerEngine.expects(:resolve).never

    When "we print usage"
    runner.run([])

    Then "the noun is listed, and down beside it"
    out.string.include?("container")
    out.string.lines.any? { |l| l.strip.start_with?("down ") }
  end

  test "#{name} is not registered when the lock pins no image" do
    Given "a Runner over a checkout pinning no image"
    runner = build_runner(commands: {})
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we invoke the absent command"
    runner.run(argv)

    Then "it is not found"
    $stderr.string.include?(name)

    Cleanup
    $stderr = old_stderr

    Where
    name        | argv
    "container" | ["container", "status"]
    "down"      | ["down"]
  end

  test "build and package are registered in Lifecycle iff the project declares targets" do
    Given "a Runner over a project with two targets, and one without"
    out = StringIO.new
    with_targets = build_runner(out: out, targets: {
      "rspock" => { "desc" => "The gem", "build" => "true" },
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
    })
    without = StringIO.new
    build_runner(out: without).run([])

    When "we print usage, then build's own"
    with_targets.run([])
    root_usage = out.string.dup
    out.truncate(0)
    out.rewind
    with_targets.run(["help", "build"])

    Then "the verbs sit in the Lifecycle section, build's usage names the bare default; the other project has neither"
    root_usage.include?("Lifecycle:")
    root_usage.lines.any? { |l| l.strip.start_with?("build ") }
    root_usage.lines.any? { |l| l.strip.start_with?("package ") }
    out.string.include?("Bare `dev build` is `rspock`.")
    without.string.lines.none? { |l| l.strip.start_with?("build ", "package ") }
  end

  test "release is registered in Lifecycle iff the project declares one; its usage lists the release builds (dev#424)" do
    Given "a project with `release: {}`, one with `release.targets`, and one with targets but no release"
    every_build = StringIO.new
    build_runner(out: every_build, targets: {
      "rspock" => { "desc" => "The gem" },
      "site" => { "desc" => "The site", "configs" => ["release"], "build" => "true" },
    }, commands: { "release" => {} }).run(["help", "release"])
    declared = StringIO.new
    build_runner(out: declared, targets: {
      "rspock" => { "desc" => "The gem" },
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
    }, commands: { "release" => { "targets" => ["site-release"] } }).run(["help", "release"])
    without = StringIO.new
    build_runner(out: without, targets: { "rspock" => { "desc" => "The gem" } }).run([])

    Expect "the verb takes a version and lists what a release contains; the other project has no release"
    every_build.string.include?("release [<version>|major|minor|patch]")
    every_build.string.include?(<<~LISTING)
      Release builds:
        rspock       The gem   host
        site-release The site  host
    LISTING
    declared.string.include?(<<~LISTING)
      Release builds:
        site-release The site  host
    LISTING
    without.string.lines.none? { |l| l.strip.start_with?("release") }
  end

  test "dev help build lists every build with its environment column" do
    Given "a Runner over a project with targets placed on the host (no image pinned)"
    out = StringIO.new
    runner = build_runner(out: out, targets: {
      "rspock" => { "desc" => "The gem" },
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
    })

    When
    runner.run(["help", "build"])

    Then
    out.string.include?(<<~LISTING)
      Builds:
        rspock       The gem   host
        site-dev     The site  host
        site-release The site  host
    LISTING
    out.string.include?("--no-build") == false
  end

  test "a build whose image does not produce its platform is reported at load and left unbound, so dev deps update stays reachable (dev#450)" do
    Given "a lock whose image declares no target_platforms, and a target asking it for win64"
    out = StringIO.new
    old_stderr = $stderr
    $stderr = StringIO.new
    runner = build_runner(out: out, root: pinned_root("snappy-linux"), targets: {
      "snappy-steam" => { "desc" => "The Steam client", "platforms" => ["win64"], "build" => "true" },
    })

    When "we print build's listing, then deps update's usage"
    runner.run(["help", "build"])
    listing = out.string.dup
    out.truncate(0)
    out.rewind
    runner.run(["deps", "update", "--help"])

    Then "the mismatch is named once on stderr, the build lists without an environment column, and the relock is served"
    $stderr.string.include?("`snappy-steam-win64` builds in snappy-linux, which does not produce win64")
    $stderr.string.include?("add `target_platforms :win64` to its image block")
    listing.include?("snappy-steam-win64 The Steam client")
    listing.include?("snappy-linux") == false
    out.string.include?("Usage: dev deps update")

    Cleanup
    $stderr = old_stderr
  end

  test "bare dev build runs the first declared target's build script with the env contract, into the store" do
    Given "a project whose first target's build script records its env"
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    data_root = root / "data"
    Dev::DataRoot.stubs(:path).returns(data_root.to_s)
    out = StringIO.new
    runner = build_runner(out: out, root: root, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "echo \"$DEV_TARGET $DEV_CONFIG\" > \"$DEV_INSTALL/env\"" },
      "rspock" => { "desc" => "The gem" },
    })

    When
    runner.run(["build"])

    Then "site-dev was built into <data root>/artifacts/<project>/site-dev/install"
    (data_root / "artifacts" / "testproject" / "site-dev" / "install" / "env").read == "site dev\n"
    out.string == "built site-dev → #{data_root / "artifacts" / "testproject" / "site-dev" / "install"}\n"
  end

  test "without an injected ledger the Runner builds the real one: GithubDeployments over a Gh at the project root" do
    Given "a project with a channel, a Runner given no deployments_factory, and the Gh class watched"
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    Dev.stubs(:target_project_root).returns(root)
    tmp = (@tmp_files ||= []).push(Tempfile.new(["dev", ".yml"])).fetch(-1)
    tmp.write(YAML.dump({ "name" => "testproject",
                          "targets" => { "site" => { "desc" => "The site", "build" => "true" } },
                          "commands" => { "deploy" => { "commands" => {
                            "staging" => { "desc" => "rsync", "targets" => ["site"], "run" => "./bin/stage", "environment" => "host" },
                          } } } }))
    tmp.flush
    out = StringIO.new
    # Built before the expectation: FakeGh is a Gh, so its `new` is the one being watched.
    fake = FakeGh.new(root:)
    Dev::Lifecycle::Gh.expects(:new).with(root: root).at_least_once.returns(fake)

    When "we print deploy's usage"
    Dev::Cli::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: fake_ui, out: out).run(["help", "deploy"])

    Then "the ledger was built over this checkout; usage never asked the forge anything"
    out.string.include?("staging")
  end

  test "without an injected archive the Runner builds the real one: GithubReleases over a Gh at the project root" do
    Given "a project with `release: {}`, a Runner given no releases_factory, and the Gh class watched"
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    Dev.stubs(:target_project_root).returns(root)
    tmp = (@tmp_files ||= []).push(Tempfile.new(["dev", ".yml"])).fetch(-1)
    tmp.write(YAML.dump({ "name" => "testproject",
                          "targets" => { "site" => { "desc" => "The site", "configs" => ["release"], "build" => "true" } },
                          "commands" => { "release" => {} } }))
    tmp.flush
    out = StringIO.new
    # Built before the expectation: FakeGh is a Gh, so its `new` is the one being watched.
    fake = FakeGh.new(root:)
    Dev::Lifecycle::Gh.expects(:new).with(root: root).at_least_once.returns(fake)

    When "we print release's usage"
    Dev::Cli::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: fake_ui, out: out).run(["help", "release"])

    Then "the archive was built over this checkout; usage never asked the forge anything"
    out.string.include?("site-release")
  end

  test "deploy is registered in Lifecycle iff the project declares a channel; its usage lists each channel's accept set and protocol" do
    Given "a project with two channels, and one with targets but none"
    out = StringIO.new
    with_channels = build_runner(out: out, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
      "rspock" => { "desc" => "The gem" },
    }, commands: {
      "deploy" => { "commands" => {
        "staging" => { "desc" => "rsync to the box", "targets" => ["site"], "run" => "./bin/stage", "environment" => "host" },
        "rubygems" => { "desc" => "gem push", "targets" => ["rspock"], "run" => "gem push \"$DEV_ARTIFACT\"", "environment" => "host" },
      } },
    })
    without = StringIO.new
    build_runner(out: without, targets: { "rspock" => { "desc" => "The gem" } }).run([])

    When "we print usage, then deploy's, then a channel's"
    with_channels.run([])
    root_usage = out.string.dup
    out.truncate(0)
    out.rewind
    with_channels.run(["help", "deploy"])
    deploy_usage = out.string.dup
    out.truncate(0)
    out.rewind
    with_channels.run(["help", "deploy", "staging"])

    Then "deploy's usage lists the channels and, beside them, dev's own `status`"
    root_usage.lines.any? { |l| l.strip.start_with?("deploy …") }
    without.string.lines.none? { |l| l.strip.start_with?("deploy") }
    deploy_usage.include?(<<~USAGE)
      Commands:
        rubygems     gem push                                                         host
                     Accepts: rspock
                     Protocol: run: gem push "$DEV_ARTIFACT"
        staging      rsync to the box                                                 host
                     Accepts: site-dev, site-release
                     Protocol: run: ./bin/stage
        status       What each channel carries and from where (status [--release V])
    USAGE
    out.string.include?("Runs on the host.\nAccepts: site-dev, site-release\nProtocol: run: ./bin/stage\n")
    out.string.include?("--allow-stale")
    out.string.include?("--dry-run")
  end

  test "dev deploy <channel> ships the stored artifact through the channel's run: line with the artifact env, never building" do
    Given "a project whose channel script records its env, and a packaged artifact in the store"
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    Open3.capture2e("git", "-C", root.to_s, "init", "-q")
    Open3.capture2e("git", "-C", root.to_s, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one")
    outside = Pathname.new(Dir.mktmpdir("runner-test-"))
    @tmp_roots.push(outside)
    data_root = outside / "data"
    Dev::DataRoot.stubs(:path).returns(data_root.to_s)
    out = StringIO.new
    gh = FakeGh.new.resolving("d3mlabs/testproject")
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/testproject/deployments"], with: { "id" => 9, "created_at" => "2026-11-05T17:02:11Z" })
      .answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/testproject/deployments/9/statuses"], with: { "state" => "success" })
    runner = build_runner(out: out, ui: Dev::NoUi.new(out: out), root: root, gh: gh, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "echo site > \"$DEV_INSTALL/index.html\"" },
    }, commands: {
      "deploy" => { "commands" => {
        "staging" => { "targets" => ["site"], "run" => "echo \"$DEV_CHANNEL $DEV_BUILD $DEV_ARTIFACT\" >> \"#{outside}/shipped\"", "environment" => "host" },
      } },
    })
    runner.run(["package", "site-release"])
    out.truncate(0)
    out.rewind

    When
    runner.run(["deploy", "staging"])

    Then "the one stored config shipped on the testing track; the script saw the channel, the build and the archive file; the deploy was recorded on the forge"
    archive = data_root / "artifacts" / "testproject" / "site-release" / "site-release.zip"
    (outside / "shipped").read == "staging site-release #{archive}\n"
    out.string.start_with?("Deploying staging (testing track)\n  site-release (")
    out.string.include?(": #{archive}\nShipping via run: echo")
    out.string.include?("✓ staging deployed! 1 archive (testing track), GitHub Deployment #9 → https://github.com/d3mlabs/testproject/deployments/staging\n")
    gh.posted.first.slice("environment", "auto_merge") == { "environment" => "staging", "auto_merge" => false }
    gh.posted.first["payload"]["builds"].map { |b| b["build"] } == ["site-release"]
    gh.posted.last["state"] == "success"
  end

  test "dev deploy --release V with no channel fans out over every channel from the release's verified archives, on the live track, recorded against the tag (dev#425)" do
    Given "a project with two channels, a release of both builds on the forge, and a forge that takes two records"
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    Open3.capture2e("git", "-C", root.to_s, "init", "-q")
    outside = Pathname.new(Dir.mktmpdir("runner-test-"))
    @tmp_roots.push(outside)
    data_root = outside / "data"
    Dev::DataRoot.stubs(:path).returns(data_root.to_s)
    out = StringIO.new
    release_json = JSON.generate({
      "stamp" => Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: Time.utc(2026, 11, 6, 12)).to_json_hash,
      "tag" => "v1.2.0", "sha" => "3f2a1c9d8e7b4455",
      "archives" => [
        { "build" => "site-release", "name" => "site-release-1.2.0.zip", "sha256" => Digest::SHA256.hexdigest("site"), "build_id" => "1.2.0+3f2a1c9d8e7b" },
        { "build" => "rspock", "name" => "rspock-1.2.0.gem", "sha256" => Digest::SHA256.hexdigest("gem"), "build_id" => "1.2.0+3f2a1c9d8e7b" },
      ],
    })
    gh = FakeGh.new.resolving("d3mlabs/testproject")
      .answers(["release", "view", "v1.2.0"], with: "https://github.com/d3mlabs/testproject/releases/tag/v1.2.0\n")
      .answers(["release", "view", "v1.2.0"], with: "https://github.com/d3mlabs/testproject/releases/tag/v1.2.0\n")
      .serves("v1.2.0", "release.json" => release_json, "site-release-1.2.0.zip" => "site", "rspock-1.2.0.gem" => "gem")
    [9, 10].each do |id|
      gh.answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/testproject/deployments"], with: { "id" => id, "created_at" => "2026-11-05T17:02:11Z" })
      gh.answers(["api", "-X", "POST", "--input", "-", "repos/d3mlabs/testproject/deployments/#{id}/statuses"], with: { "state" => "success" })
    end
    runner = build_runner(out: out, ui: Dev::NoUi.new(out: out), root: root, gh: gh, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
      "rspock" => { "desc" => "The gem" },
    }, commands: {
      "deploy" => { "commands" => {
        "staging" => { "targets" => ["site-release"], "run" => "echo \"$DEV_CHANNEL $DEV_TRACK $DEV_RELEASE_VERSION $DEV_ARTIFACT\" >> \"#{outside}/shipped\"", "environment" => "host" },
        "rubygems" => { "targets" => ["rspock"], "run" => "echo \"$DEV_CHANNEL $DEV_TRACK $DEV_RELEASE_VERSION $DEV_ARTIFACT\" >> \"#{outside}/shipped\"", "environment" => "host" },
      } },
    })

    When
    runner.run(["deploy", "--release", "1.2.0"])

    Then "nothing was packaged here; each channel shipped its archive from .releases/v1.2.0/ live; both records name the tag"
    releases = data_root / "artifacts" / "testproject" / ".releases" / "v1.2.0"
    (outside / "shipped").read == "staging live 1.2.0 #{releases / "site-release-1.2.0.zip"}\nrubygems live 1.2.0 #{releases / "rspock-1.2.0.gem"}\n"
    !(data_root / "artifacts" / "testproject" / "site-release").exist?
    out.string.lines.first == "deploy staging --release 1.2.0\n"
    out.string.lines.last == "✓ v1.2.0 shipped to 2 channels: staging, rubygems\n"
    gh.posted.select { |body| body.key?("ref") }.map { |body| [body["environment"], body["ref"], body["payload"]["track"], body["production_environment"]] } ==
      [["staging", "v1.2.0", "live", true], ["rubygems", "v1.2.0", "live", true]]
  end

  test "dev deploy status reads each channel's latest deployment from the forge" do
    Given "a project with a channel, and a forge holding one deployment for it"
    out = StringIO.new
    gh = FakeGh.new.resolving("d3mlabs/testproject")
      .answers(["api", "repos/d3mlabs/testproject/deployments?environment=staging&per_page=1"], with: [{
        "id" => 9, "ref" => "0123456789ab", "created_at" => "2026-11-05T17:02:11Z",
        "payload" => { "schema" => 1, "track" => "testing", "builds" => [{ "build" => "site-release", "build_id" => "0.0.0+0123456789ab" }] },
      }])
      .answers(["api", "repos/d3mlabs/testproject/deployments/9/statuses?per_page=1"], with: [{ "state" => "success", "description" => "run: ./bin/stage" }])
    runner = build_runner(out: out, gh: gh, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
    }, commands: {
      "deploy" => { "commands" => { "staging" => { "targets" => ["site"], "run" => "./bin/stage", "environment" => "host" } } },
    })

    When
    runner.run(["deploy", "status"])

    Then
    out.string == <<~OUT
      staging  ✓ testing from 0123456789ab at 2026-11-05 17:02 UTC — run: ./bin/stage
               site-release (0.0.0+0123456789ab)
    OUT
  end

  test "a channel the lock contributes is a deploy child without a run: line: declared, its targets: configure it; undeclared, it accepts every packageable build (dev#422)" do
    Given "a lock contributing a steam publisher, and a project declaring steam without run: beside a script channel"
    steam = RecordingPublisher.new
    Dev::Deps::Registry.stubs(:publishers).returns({ "steam" => steam })
    out = StringIO.new
    configured = build_runner(out: out, targets: {
      "site" => { "desc" => "The site", "configs" => ["dev", "release"], "build" => "true" },
      "rspock" => { "desc" => "The gem" },
    }, commands: {
      "deploy" => { "commands" => {
        "staging" => { "desc" => "rsync to the box", "targets" => ["site"], "run" => "./bin/stage", "environment" => "host" },
        "steam" => { "desc" => "Steam depots", "targets" => ["site-release"] },
      } },
    })
    undeclared_out = StringIO.new
    undeclared = build_runner(out: undeclared_out, targets: { "rspock" => { "desc" => "The gem" } })

    When "we print deploy's usage for each"
    configured.run(["help", "deploy"])
    undeclared.run(["help", "deploy"])

    Then "the declared one keeps its targets: and desc over the integration's protocol; the undeclared one appears as the lock's, over every build; " \
         "dev's own `status` sits among them either way"
    out.string.include?(<<~USAGE)
      Commands:
        staging      rsync to the box                                                 host
                     Accepts: site-dev, site-release
                     Protocol: run: ./bin/stage
        status       What each channel carries and from where (status [--release V])
        steam        Steam depots                                                     host
                     Accepts: site-release
                     Protocol: publisher: steam
    USAGE
    undeclared_out.string.include?(<<~USAGE)
      Commands:
        status       What each channel carries and from where (status [--release V])
        steam        Ship through the lock's steam publisher                          host
                     Accepts: rspock
                     Protocol: publisher: steam
    USAGE
  end

  test "a deploy child with neither run: nor a publisher the lock contributes binds with its fault: every other verb runs, help names the fault, and only `deploy <channel>` refuses (dev#509)" do
    Given "a project declaring steam without run: over a lock pinning nothing — dev ships the steam publisher, the lock reaches it with no pin"
    out = StringIO.new
    runner = build_runner(out: out, targets: { "rspock" => { "desc" => "The gem" } }, commands: {
      "deploy" => { "commands" => { "steam" => { "desc" => "Steam depots", "targets" => ["rspock"] } } },
    })
    old_stderr = $stderr
    $stderr = StringIO.new

    When "help runs, then the channel is asked to ship"
    runner.run(["help", "deploy"])
    Kernel.expects(:exit).with(1).once
    runner.run(["deploy", "steam"])

    Then "help listed it, protocol-less, and the deploy was refused with the protocol message — load itself said nothing"
    out.string.include?("steam        Steam depots")
    out.string.include?("Protocol: publisher: steam — deps.lock pins no `steam`")
    $stderr.string.include?("dev: channel 'deploy steam' has no protocol: it declares no `run:` and deps.lock pins no `steam`")
    $stderr.string.include?("depend on one in dependencies.rb and `dev deps update`, or declare `run:`")
    $stderr.string.lines.count { |line| line.include?("has no protocol") } == 1

    Cleanup
    $stderr = old_stderr
  end

  test "runner is ungated: every project catalog lists it" do
    Given "a Runner with a plain dev.yml (no runner block — the key is retired)"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "we print usage, then the runner group's usage"
    runner.run([])
    runner.run(["runner"])

    Then "the runner group is listed once (the runner-setup alias is retired, #184), with register and status beneath"
    out.string.include?("  runner …     Enroll, inspect or unenroll this host as a self-hosted runner")
    !out.string.include?("runner-setup")
    out.string.include?("Usage: dev runner <command> [args...]")
    out.string.include?("  register     Enroll this host")
    out.string.include?("  status       Inspect this host's runner enrollments")
  end

  test "a leftover dev.yml runner block warns and is ignored" do
    Given "a dev.yml still carrying the retired key"
    out = StringIO.new
    old_stderr = $stderr
    $stderr = StringIO.new
    runner = build_runner(commands: {}, runner: { "labels" => "ue-engine" }, out: out)

    When "we print usage"
    runner.run([])

    Then "the run proceeds with a retirement warning"
    $stderr.string.include?("`runner:` is retired")
    out.string.include?("  runner …     Enroll, inspect or unenroll this host as a self-hosted runner")

    Cleanup
    $stderr = old_stderr
  end

  test "a project group invoked bare prints its usage, and lists as a group in the top-level usage" do
    Given "a dev.yml with a nested test group"
    out = StringIO.new
    runner = build_runner(
      commands: {
        "test" => {
          "desc" => "Test suites",
          "commands" => { "unit" => { "run" => "rspec spec/unit", "desc" => "Unit tests" } },
        },
      },
      out: out,
    )

    When "running the group bare, then the top-level usage"
    runner.run(["test"])
    runner.run([])

    Then "the group's usage renders, and the top-level marks it as a group"
    out.string.include?("Usage: dev test <command> [args...]")
    out.string.include?("  unit         Unit tests")
    out.string.include?("  test …       Test suites")
  end

  test "the deps builtin is a group: bare it prints its usage, listing update, install, check and path" do
    Given "a Runner"
    out = StringIO.new
    runner = build_runner(commands: {}, out: out)

    When "running deps bare"
    runner.run(["deps"])

    Then "the group usage renders the four leaves and nothing else"
    out.string.include?("Usage: dev deps <command> [args...]")
    rows = out.string.lines.map(&:chomp).select { |l| l.start_with?("  ") }
    rows.map { |l| l.split.first } == %w[check install path update]
    out.string.include?("  update       Resolve dependency constraints and write lockfiles")
    out.string.include?("  install      Install locked dependencies on this machine")
    out.string.include?("  check        Check dependency state freshness")
    out.string.include?("  path         Print a locked artifact's path")
  end

  test "dev complete walks the project catalog: top level, then a group's children" do
    Given "a dev.yml with a nested test group"
    out = StringIO.new
    runner = build_runner(
      commands: {
        "test" => {
          "desc" => "Test suites",
          "commands" => { "unit" => { "run" => "rspec spec/unit" }, "e2e" => { "run" => "rspec spec/e2e" } },
        },
      },
      out: out,
    )

    When "completing at the top level, then inside the group"
    runner.run(["complete"])
    top = out.string.lines.map(&:chomp)
    out.truncate(0)
    out.rewind
    runner.run(%w[complete test])
    inside = out.string.lines.map(&:chomp)

    Then "builtins, groups and project commands at the top; the group's children inside; complete and pack hidden"
    (%w[help up deps plan test] - top).empty?
    !top.include?("complete")
    !top.include?("pack")
    inside == %w[e2e unit]
  end

  test "dev pack is a hidden project builtin: callable, absent from the usage" do
    Given "a Runner over an empty dev.yml, and a directory to archive"
    out = StringIO.new
    runner = build_runner(out: out)
    install = Pathname(Dir.mktmpdir("runner-pack-"))
    (@tmp_roots ||= []).push(install)
    (install / "a.txt").write("a")
    stem = install / "out/archive"

    When "listing the usage, then packing"
    runner.run(["help"])
    usage = out.string
    out.truncate(0)
    out.rewind
    runner.run(["pack", install.to_s, "--out", stem.to_s])

    Then "the usage never names pack; the zip is written and printed"
    !usage.include?(" pack ")
    out.string == "#{stem}.zip\n"
    (install / "out/archive.zip").file?
  end

  test "dev complete outside a project offers the projectless catalog, global commands included" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "completing at the top level"
    runner.run(["complete"])

    Then "help, up, runner and the global nouns are offered; project-only builtins are not"
    names = out.string.lines.map(&:chomp)
    (%w[help up runner cd clone config cred engine learnings plan skills] - names).empty?
    !names.include?("deps")
  end

  test "bare dev outside a project prints the projectless root: the global commands and the dev.yml hint" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "running bare"
    runner.run([])

    Then "the global commands render with their canonical descriptions, in sections, closing with the hint"
    out.string.include?("Usage: dev <command> [args...]")
    out.string.include?("Commands available outside a project")
    out.string.include?("  cd           #{Dev::Cli::Builtins::CdCommand::DESC}")
    out.string.include?("  clone        #{Dev::Cli::Builtins::CloneCommand::DESC}")
    out.string.include?("  config …     Manage dev settings")
    out.string.include?("  cred …       Resolve stored credentials")
    out.string.include?("  learnings …  The learnings read path: org knowledge cache, skill links, invariants")
    out.string.include?("  plan …       Sync Cursor plans with GitHub issues")
    out.string.include?("  skills …     Skill materialization: every channel dev links into an agent's discovery roots")
    out.string.include?("  runner …     Enroll, inspect or unenroll this host as a self-hosted runner")
    out.string.include?("Environment:")
    out.string.lines.last == "#{Dev::Cli::Runner::PROJECTLESS_EPILOGUE}\n"
  end

  test "dev help <path> outside a project renders a global group's usage" do
    Given "a Runner with no dev.yml, over its real service graph"
    out = StringIO.new
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: out)

    When "asking for help on plan"
    runner.run(["help", "plan"])

    Then
    out.string.include?("Usage: dev plan <command> [args...]")
    out.string.include?("  pull")
  end

  test "dev help learnings says where capture lives, which the root listing leaves out" do
    Given "a Runner with no dev.yml, over its real service graph"
    help_out = StringIO.new
    root_out = StringIO.new

    When "asking for the learnings group's usage and the root listing"
    Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: help_out).run(["help", "learnings"])
    Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: root_out).run([])

    Then "the group's usage carries the capture pointer; the root keeps the one-line summary"
    help_out.string.include?("Capture is agent-driven, not a dev verb: the capture-learning skill")
    help_out.string.include?("ai-flow's /learn on GitHub")
    !root_out.string.include?("Capture is agent-driven")
  end

  test "an unknown child of a pure project group is reported with its full path" do
    Given "a dev.yml with a nested test group"
    runner = build_runner(
      commands: { "test" => { "commands" => { "unit" => { "run" => "rspec" } } } },
    )
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running an unknown child"
    runner.run(["test", "bogus"])

    Then "the error names the path as typed"
    $stderr.string.include?("Command 'test bogus' not found")

    Cleanup
    $stderr = old_stderr
  end

  test "run assembles the execution context and hands the command to the service" do
    Given "a Runner over an expecting command service, with a declared toolchain"
    root = Pathname.new(Dir.mktmpdir("runner-context-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "9.9.9"
        python "3.12"
      end
    RUBY
    contexts = []
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).with { |argv, context:|
      contexts << [argv, context]
      true }
    ui = fake_ui
    runner = build_runner(commands: {}, command_service: command_service, ui: ui, root: root)

    When "we run a command with args"
    runner.run(["test", "--fast"])

    Then "the service got the argv and a fully-assembled context"
    argv, context = contexts.fetch(0)
    argv == ["test", "--fast"]
    context.ui == ui
    context.project!.root == root

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the project context carries the dev.yml runner roles, so register can resolve --role (dev#566)" do
    Given "a Runner over a dev.yml declaring a farm role"
    contexts = []
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).with { |argv, context:|
      contexts << [argv, context]
      true }
    runner = build_runner(runner_roles: { "ue-farm" => { "labels" => %w[ue gpu] } }, command_service: command_service)

    When
    runner.run(["test"])

    Then
    contexts.fetch(0).last.project!.runner_roles == { "ue-farm" => Dev::RunnerRole.user(name: "ue-farm", labels: %w[ue gpu]) }
  end

  test "run without a dev.yml assembles a projectless context" do
    Given "a Runner constructed with no dev.yml anywhere"
    contexts = []
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).with { |argv, context:|
      contexts << [argv, context]
      true }
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, command_service: command_service)

    When "running up"
    runner.run(["up"])

    Then "the service got a context with a ui and no project half"
    argv, context = contexts.fetch(0)
    argv == ["up"]
    context.project.nil?
  end

  test "a project command without a dev.yml maps to the no-dev.yml refusal" do
    Given "a Runner with no dev.yml, over its real service graph"
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running a project command"
    runner.run(["test"])

    Then "the refusal names the missing dev.yml"
    $stderr.string.include?("no dev.yml found in this directory or any parent")
    $stderr.string.include?("Run dev from inside a project that defines a dev.yml.")

    Cleanup
    $stderr = old_stderr
  end

  test "project builtins are not registered without a dev.yml" do
    Given "a Runner with no dev.yml, over its real service graph"
    runner = Dev::Cli::Runner.new(dev_yaml_path: nil, ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running a project-scoped builtin"
    runner.run(%w[deps install])

    Then "the lookup fails like any other command outside a project"
    $stderr.string.include?("no dev.yml found in this directory or any parent")

    Cleanup
    $stderr = old_stderr
  end

  test "a dev.yml with the removed ruby: key maps to a clean error inside run" do
    Given "a Runner over a dev.yml that still carries ruby:"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(YAML.dump({ "name" => "testproject", "ruby" => "3.3.0", "commands" => {} }))
    tmp.flush
    runner = Dev::Cli::Runner.new(dev_yaml_path: Pathname.new(tmp.path), ui: fake_ui, out: StringIO.new)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "running any command"
    runner.run(["test"])

    Then "the migration message reaches stderr as a dev: error"
    $stderr.string.include?("dev.yml `ruby:` is no longer supported")

    Cleanup
    $stderr = old_stderr
    tmp.close!
  end

  test "a failed waited child exits with the child's status" do
    Given "a Runner whose service raises the child's failure"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(Dev::Cli::CommandRunner::CommandFailedError.new(exit_status: 7))
    runner = build_runner(commands: {}, command_service: command_service)
    Kernel.expects(:exit).with(7).once

    When "we run the command"
    runner.run(["up"])

    Then "the expectation on the exit mapping holds"
    true
  end

  test "a signal-killed child exits 128 plus the signal number" do
    Given "a Runner whose service raises the child's signal death"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(Dev::Cli::CommandRunner::CommandKilledError.new(signal: 15))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(143).once

    When "we run the command"
    runner.run(["up"])

    Then "the signal is reported under the dev: prefix"
    $stderr.string.include?("dev: command killed by signal 15")

    Cleanup
    $stderr = old_stderr
  end

  test "a child that never spawned exits 127" do
    Given "a Runner whose service raises the spawn failure"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(Dev::Cli::CommandRunner::CommandSpawnError.new)
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(127).once

    When "we run the command"
    runner.run(["up"])

    Then "the spawn failure is reported under the dev: prefix"
    $stderr.string.include?("dev: command could not be spawned")

    Cleanup
    $stderr = old_stderr
  end

  test "an ArgumentError is reported as a clean dev error with exit 1" do
    Given "a Runner whose service raises a usage error"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(ArgumentError.new("usage: dev cache gc [--keep N]"))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run the command"
    runner.run(["cache"])

    Then "the message reaches stderr under the dev: prefix"
    $stderr.string.include?("dev: usage: dev cache gc [--keep N]")

    Cleanup
    $stderr = old_stderr
  end

  test "GitHub refusing a runner query is a clean dev error with exit 1, not a backtrace (dev#493)" do
    Given "a Runner whose service surfaces the registry's refusal"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(Dev::RunnerRegistry::QueryError.new("gh api orgs/d3mlabs/actions/runner-groups failed (HTTP 403)"))
    runner = build_runner(commands: {}, command_service: command_service)
    old_stderr = $stderr
    $stderr = StringIO.new
    Kernel.expects(:exit).with(1).once

    When "we run the command"
    runner.run(["runner", "register"])

    Then "GitHub's words reach stderr under the dev: prefix"
    $stderr.string.include?("dev: gh api orgs/d3mlabs/actions/runner-groups failed (HTTP 403)")

    Cleanup
    $stderr = old_stderr
  end

  test "an unmapped error is a dev bug and re-raises with its backtrace" do
    Given "a Runner whose service raises an unmapped error class"
    command_service = typed_mock(Dev::Cli::CommandService)
    command_service.stubs(:execute).raises(Dev::Deps::ArtifactStore::PublishOutsideStagingError.new("elsewhere"))
    runner = build_runner(commands: {}, command_service: command_service)

    When "we run the command"
    runner.run(["deps"])

    Then
    raises Dev::Deps::ArtifactStore::PublishOutsideStagingError
  end

  private

  # Every run builds an ExecutionContext, so the helper always pins the
  # project root to a temp dir; tests needing their own pass a root.
  def build_runner(name: "testproject", commands: {}, targets: nil, runner: nil, runner_roles: nil, command_service: nil,
    ui: fake_ui, out: StringIO.new, root: nil, gh: FakeGh.new)
    root ||= (@tmp_roots ||= []).push(Pathname.new(Dir.mktmpdir("runner-test-"))).fetch(-1)
    Dev.stubs(:target_project_root).returns(root)

    yaml = { "name" => name, "commands" => commands }
    yaml["targets"] = targets if targets
    yaml["runner"] = runner if runner
    yaml["runner_roles"] = runner_roles if runner_roles
    # Held in @tmp_files until teardown: a Tempfile that falls out of scope is
    # unlinked by its finalizer at the next GC, under a Runner still reading it.
    tmp = (@tmp_files ||= []).push(Tempfile.new(["dev", ".yml"])).fetch(-1)
    tmp.write(YAML.dump(yaml))
    tmp.flush

    # The deployment ledger and the release archive are the forge: scripted, never reached.
    Dev::Cli::Runner.new(
      dev_yaml_path: Pathname.new(tmp.path), ui: ui, out: out, command_service: command_service,
      deployments_factory: ->(_root) { Dev::Lifecycle::GithubDeployments.new(gh:) },
      releases_factory: ->(_root) { Dev::Lifecycle::GithubReleases.new(gh:) },
    )
  end

  # A checkout whose lock pins these images (dev#277), removed in teardown.
  def pinned_root(*names)
    root = Pathname.new(Dir.mktmpdir("runner-test-"))
    (@tmp_roots ||= []).push(root)
    pins = names.map do |name|
      Dev::Deps::Dependency.new(
        name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
          "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [],
        },
      )
    end
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp(pins))
    root
  end

  def teardown
    restore_host_probe_guard(@host_probes)
    @tmp_roots&.each { |root| FileUtils.rm_rf(root) }
    @tmp_files&.each(&:close!)
    super
  end

  def fake_ui
    ui = typed_mock(Dev::Ui)
    ui.stubs(:print_header)
    ui
  end
end
