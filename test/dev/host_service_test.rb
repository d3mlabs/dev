# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/host_service"
require "dev/settings"
require "fileutils"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::HostServiceTest < Minitest::Test
  include SorbetHelper

  # Records every brew invocation instead of running it — the executor is
  # the true boundary; everything else (settings layers, Brewfile) uses
  # real files in temp dirs.
  class RecordingExecutor
    attr_reader :commands

    # @param fail_subcommands [Array<String>] brew subcommands whose run
    #   reports failure (e.g. ["upgrade"]), for the warn-only branches
    def initialize(run_result: true, quiet_result: false, fail_subcommands: [])
      @commands = []
      @run_result = run_result
      @quiet_result = quiet_result
      @fail_subcommands = fail_subcommands
    end

    def run(*cmd)
      @commands << cmd
      return false if @fail_subcommands.include?(cmd[1])

      @run_result
    end

    def quiet?(*cmd)
      @commands << cmd
      @quiet_result
    end
  end

  test "converge_tooling is a no-op on a brewless machine (no system config location)" do
    Given "settings that resolve no brew prefix"
    dir = Dir.mktmpdir("dev-host-service-test-")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)
    service.instance_variable_get(:@settings).stubs(:system_config_path).returns(nil)

    When "converging the tooling"
    service.converge_tooling

    Then "brew is never invoked"
    executor.commands.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a bare host runs the self-update but has nothing to upgrade or bundle" do
    Given "no deployment config, no Brewfile, dev-core not brew-installed"
    dir = Dir.mktmpdir("dev-host-service-test-")
    executor = RecordingExecutor.new(quiet_result: false)
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    service.converge_tooling

    Then "brew update + the dev-core check ran, nothing upgraded or bundled"
    executor.commands == [
      ["brew", "update", "--quiet"],
      ["brew", "list", "--formula", "--versions", "dev-core"],
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a named deployment upgrades exactly that formula" do
    Given "a system config naming the deployment"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "the scoped upgrade targets the self-named formula, with no warning"
    executor.commands.include?(["brew", "upgrade", "--quiet", "d3mlabs/d3mlabs/dev"])
    stderr.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a malformed deployment_formula never reaches brew" do
    Given "a hostile value that would parse as a brew flag"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, 'deployment_formula: "--force evil"' + "\n")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "no upgrade is attempted and the rejection is warned"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("malformed deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "'#{formula}' (#{shape}) keeps its spelling through to brew upgrade" do
    Given "a deployment named with that token shape"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "deployment_formula: #{formula}\n")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "the scoped upgrade targets the formula as spelled, with no warning"
    executor.commands.include?(["brew", "upgrade", "--quiet", formula])
    stderr.empty?

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    formula             | shape
    "d3mlabs/tap/dev@2" | "tap-qualified versioned"
    "org/tap/libc++"    | "tap-qualified plused"
  end

  test "'#{formula}' (#{reason}) is rejected as malformed" do
    Given "a deployment_formula that is not a canonical brew token"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "deployment_formula: #{formula}\n")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "no upgrade is attempted and the rejection is warned"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("malformed deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    formula    | reason
    "foo/bar"  | "two segments is not a formula reference"
    "Dev-Core" | "brew's canonical tap form is lowercase"
  end

  test "an unset key falls back to dev-core when it is brew-installed" do
    Given "no deployment config, dev-core installed"
    dir = Dir.mktmpdir("dev-host-service-test-")
    executor = RecordingExecutor.new(quiet_result: true)
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    service.converge_tooling

    Then "the tapless individual's tool self-updates"
    executor.commands.include?(["brew", "upgrade", "--quiet", "dev-core"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a Brewfile beside the system config converges via brew bundle" do
    Given "an org Brewfile in etc"
    dir = Dir.mktmpdir("dev-host-service-test-")
    brewfile = write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(quiet_result: false)
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    service.converge_tooling

    Then "brew bundle runs against the etc Brewfile as the last step"
    executor.commands.last == ["brew", "bundle", "install", "--file=#{brewfile}"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed scoped upgrade warns and still converges the Brewfile" do
    Given "a named deployment whose upgrade fails"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    brewfile = write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(fail_subcommands: ["upgrade"])
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "the failure is a warning and the Brewfile step still ran"
    stderr.include?("brew upgrade d3mlabs/d3mlabs/dev failed")
    executor.commands.last == ["brew", "bundle", "install", "--file=#{brewfile}"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew bundle warns instead of blocking" do
    Given "an org Brewfile whose converge fails"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_brewfile(dir, %(cask "cursor-cli"\n))
    executor = RecordingExecutor.new(quiet_result: false, fail_subcommands: ["bundle"])
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "the failure surfaces as a warning naming the Brewfile"
    stderr.include?("brew bundle failed")
    stderr.include?("Brewfile")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed brew update warns and skips the upgrade, but the Brewfile still converges" do
    Given "an offline machine (every streamed brew command fails)"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    executor = RecordingExecutor.new(run_result: false)
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "no upgrade was attempted and the failure is a warning"
    executor.commands.none? { |cmd| cmd[0..1] == ["brew", "upgrade"] }
    stderr.include?("brew update failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the real brew executor's run maps exit status to a boolean" do
    Given "the production executor"
    executor = Dev::HostService::BrewExecutor.new

    Expect "success and failure map to booleans, and a missing binary is false"
    executor.run(RbConfig.ruby, "-e", "exit 0") == true
    executor.run(RbConfig.ruby, "-e", "exit 1") == false
    executor.run("definitely-not-a-command-#{Process.pid}") == false
  end

  test "the real brew executor's quiet? answers success without streaming output" do
    Given "the production executor"
    executor = Dev::HostService::BrewExecutor.new

    Expect "exit status maps to a boolean and a missing binary is false, not an exception"
    executor.quiet?(RbConfig.ruby, "-e", "puts :ok") == true
    executor.quiet?(RbConfig.ruby, "-e", "exit 1") == false
    executor.quiet?("definitely-not-a-command-#{Process.pid}") == false
  end

  test "an etc config.yml without a resolvable deployment_formula warns with the remedy" do
    Given "a deployment config that forgot to name itself"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "plans_repo: acme/plans\n")
    service = build_service(dir, brew_executor: RecordingExecutor.new)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "the warning names the failure and the one-command fix"
    stderr.include?("no deployment_formula is set")
    stderr.include?("dev config set deployment_formula")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the unnamed-deployment warning is silenced by a higher layer naming it" do
    Given "a keyless system config but a user file naming the deployment"
    dir = Dir.mktmpdir("dev-host-service-test-")
    write_system_config(dir, "plans_repo: acme/plans\n")
    write_user_config(dir, "deployment_formula: acme/tap/dev\n")
    executor = RecordingExecutor.new
    service = build_service(dir, brew_executor: executor)

    When "converging the tooling"
    stderr = capture_stderr { service.converge_tooling }

    Then "no warning, and the user-layer target is upgraded"
    stderr.empty?
    executor.commands.include?(["brew", "upgrade", "--quiet", "acme/tap/dev"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_rc_hook delegates to the shell RC hook installer" do
    Given "a service over a mocked hook installer"
    dir = Dir.mktmpdir("dev-host-service-test-")
    hook_installer = typed_mock(Dev::Cd::HookInstaller)
    service = build_service(dir, hook_installer: hook_installer)

    When "ensuring the RC hook"
    service.install_rc_hook

    Then "the installer received ensure_installed"
    1 * hook_installer.ensure_installed >> :added

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync_skills outside any project materializes only dev's own channel" do
    Given "a service over a mocked materializer"
    dir = Dir.mktmpdir("dev-host-service-test-")
    materializer = typed_mock(Dev::Skills::Materializer)
    own = Dev::Skills::OwnSkills.new(root: File.join(dir, "global"))
    service = build_service(dir, materializer: materializer, own_skills: own)

    When "syncing skills with no project context"
    service.sync_skills

    Then "the materializer received the own channel alone"
    1 * materializer.sync([own])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync_skills inside a project adds the project's gem channel" do
    Given "a service over a mocked materializer and a recording gem channel factory"
    dir = Dir.mktmpdir("dev-host-service-test-")
    materializer = typed_mock(Dev::Skills::Materializer)
    own = Dev::Skills::OwnSkills.new(root: File.join(dir, "global"))
    gem = Dev::Skills::CorpusChannel.new(name: "gem", root: File.join(dir, "project"), corpus_root: File.join(dir, "gems"))
    roots = []
    factory = lambda do |project_root|
      roots << project_root
      gem
    end
    service = build_service(dir, materializer: materializer, own_skills: own, gem_skills_factory: factory)

    When "syncing skills inside a project"
    service.sync_skills(project_root: "/tmp/some-project")

    Then "the gem channel was built for that project and materialized after the own channel"
    1 * materializer.sync([own, gem])
    roots == [Pathname("/tmp/some-project")]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync_skills inside a project sweeps the legacy flat gem links before materializing" do
    Given "a project carrying a pre-#250 gem link and a user link in its skills dir"
    dir = Dir.mktmpdir("dev-host-service-test-")
    project = Pathname(dir) / "repo"
    skills = project / ".agents" / "skills"
    FileUtils.mkdir_p(skills)
    File.symlink("/nowhere/rspock", skills / "gem-rspock--rspock")
    File.symlink("/nowhere/mine", skills / "mine")
    materializer = typed_mock(Dev::Skills::Materializer)
    materializer.stubs(:sync)
    own = Dev::Skills::OwnSkills.new(root: File.join(dir, "global"))
    gem = Dev::Skills::CorpusChannel.new(name: "gem", root: skills / "dev", corpus_root: File.join(dir, "gems"))
    service = build_service(dir, materializer: materializer, own_skills: own, gem_skills_factory: ->(_root) { gem })

    When "syncing skills inside the project"
    service.sync_skills(project_root: project)

    Then "the legacy link is gone, the user's stands"
    !File.symlink?(skills / "gem-rspock--rspock")
    File.symlink?(skills / "mine")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "skill_channels lists own, org (when configured), and gem (when in a project), in that order" do
    Given "a service with a configured synchronizer and a gem channel factory"
    dir = Dir.mktmpdir("dev-host-service-test-")
    own = Dev::Skills::OwnSkills.new(root: File.join(dir, "global"))
    gem = Dev::Skills::CorpusChannel.new(name: "gem", root: File.join(dir, "project"), corpus_root: File.join(dir, "gems"))
    org = Dev::Skills::CorpusChannel.new(name: "org", root: File.join(dir, "global"), corpus_root: File.join(dir, "cache"))
    synchronizer = typed_mock(Dev::Learnings::Synchronizer)
    synchronizer.stubs(:org_channel).returns(org)
    service = build_service(dir, own_skills: own, gem_skills_factory: ->(_root) { gem }, synchronizer: synchronizer)

    Expect "all three in a project, own + org outside one"
    service.skill_channels(project_root: "/tmp/some-project") == [own, org, gem]
    service.skill_channels == [own, org]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "skill_channels skips the org channel on an unconfigured machine" do
    Given "a service whose synchronizer is the unconfigured null object"
    dir = Dir.mktmpdir("dev-host-service-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    own = Dev::Skills::OwnSkills.new(root: File.join(dir, "global"))
    service = build_service(dir, own_skills: own)

    Expect "only the own channel"
    service.skill_channels == [own]

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "sync_learnings hands the project root to the best-effort synchronizer" do
    Given "a service over a mocked synchronizer"
    dir = Dir.mktmpdir("dev-host-service-test-")
    synchronizer = typed_mock(Dev::Learnings::Synchronizer)
    service = build_service(dir, synchronizer: synchronizer)

    When "syncing learnings inside a project"
    service.sync_learnings(project_root: Pathname.new("/tmp/some-project"))

    Then "the synchronizer received the best-effort sync with the root"
    1 * synchronizer.sync(project_root: Pathname.new("/tmp/some-project"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "sync_learnings outside any project syncs the machine-global parts" do
    Given "a service over a mocked synchronizer"
    dir = Dir.mktmpdir("dev-host-service-test-")
    synchronizer = typed_mock(Dev::Learnings::Synchronizer)
    service = build_service(dir, synchronizer: synchronizer)

    When "syncing learnings with no project context"
    service.sync_learnings

    Then "the synchronizer received a nil project root"
    1 * synchronizer.sync(project_root: nil)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  private

  # Hermetic service: settings layers and Brewfile live under the test's
  # temp dir; the brew executor is faked, and the delegation collaborators
  # are injectable per test.
  def build_service(dir, brew_executor: RecordingExecutor.new, hook_installer: Dev::Cd::HookInstaller.new,
                    materializer: Dev::Skills::Materializer.new,
                    own_skills: Dev::Skills::OwnSkills.new(root: File.join(dir, "global")),
                    gem_skills_factory: ->(root) { Dev::Deps::GemSkills.new(project_root: root) },
                    synchronizer: nil)
    settings = Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "etc", "config.yml"),
    )
    Dev::HostService.new(
      settings: settings,
      brew_executor: brew_executor,
      hook_installer: hook_installer,
      materializer: materializer,
      own_skills: own_skills,
      gem_skills_factory: gem_skills_factory,
      synchronizer: synchronizer || Dev::Learnings::Synchronizer.for(settings: settings, materializer: materializer),
    )
  end

  def write_system_config(dir, content)
    path = File.join(dir, "etc", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_user_config(dir, content)
    path = File.join(dir, "user", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # @return [String] the Brewfile path (beside the system config, as a
  #   deployment ships it)
  def write_brewfile(dir, content)
    path = File.join(dir, "etc", "Brewfile")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def capture_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end
