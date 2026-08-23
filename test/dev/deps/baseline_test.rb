# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/baseline"
require "digest"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BaselineTest < Minitest::Test
  MANIFEST = <<~MANIFEST
    Dev::Deps.define do
      group :baseline do
        brew "git"
      end
    end
  MANIFEST

  # Stands in for BrewIntegration at the factory seam: records what would
  # install, touches nothing on the host.
  class RecordingIntegration
    attr_reader :installed

    def initialize
      @installed = []
    end

    def install_all(dependencies)
      @installed.concat(dependencies)
    end
  end

  # Stands in for the gh raw-content boundary: serves canned manifest
  # content (nil = fetch failure) and records every fetch.
  class FakeFetcher
    attr_reader :fetches

    def initialize(content)
      @content = content
      @fetches = []
    end

    def repo_file(owner_repo, path)
      @fetches << [owner_repo, path]
      @content
    end
  end

  def settings_with_baseline_repo(dir, repo)
    config_path = File.join(dir, "config.yml")
    File.write(config_path, repo ? "baseline_repo: #{repo}\n" : "")
    Dev::Settings.new(config_path: config_path, system_config_path: File.join(dir, "no-system.yml"))
  end

  def build_baseline(dir, repo: "acme/knowledge", fetcher: FakeFetcher.new(MANIFEST),
    integration: RecordingIntegration.new)
    saved_env = ENV.delete("DEV_BASELINE_REPO")
    baseline = Dev::Deps::Baseline.new(
      settings: settings_with_baseline_repo(dir, repo),
      state_dir: File.join(dir, "state"),
      fetcher: fetcher,
      integrations_factory: -> { { brew: integration } },
    )
    ENV["DEV_BASELINE_REPO"] = saved_env if saved_env
    baseline
  end

  def cache_path(dir)
    File.join(dir, "state", "host-baseline", "dependencies.rb")
  end

  def stamp_path(dir)
    File.join(dir, "state", "host-baseline", "converged-digest")
  end

  test "a never-converged host reports the baseline message without fetching" do
    Given "a configured baseline repo and no stamp on this host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    fetcher = FakeFetcher.new(MANIFEST)
    baseline = build_baseline(dir, fetcher: fetcher)

    Expect "the warn-only nag with its remediation, computed offline"
    baseline.message == "host baseline stale — run `dev up`"
    fetcher.fetches.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale fetches the manifest, caches it, installs, and stamps" do
    Given "a stale host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    fetcher = FakeFetcher.new(MANIFEST)
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, fetcher: fetcher, integration: integration)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then "one fetch of the conventional path; the brew dep landed (lockless: no version); the host went quiet"
    converged == true
    fetcher.fetches == [["acme/knowledge", "baseline/dependencies.rb"]]
    integration.installed.map(&:name) == ["git"]
    integration.installed.fetch(0).integration == :brew
    integration.installed.fetch(0).version.nil?
    File.read(cache_path(dir)) == MANIFEST
    File.read(stamp_path(dir)) == Digest::SHA256.hexdigest(MANIFEST)
    baseline.message.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale is a no-op install on a warm host" do
    Given "a host already converged on the upstream manifest"
    dir = Dir.mktmpdir("dev-baseline-test-")
    build_baseline(dir).converge_if_stale
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, integration: integration)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then "nothing installed"
    converged == false
    integration.installed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an upstream manifest change (an org baseline bump) makes a converged host stale again" do
    Given "a converged host whose org manifest then grows a tool"
    dir = Dir.mktmpdir("dev-baseline-test-")
    build_baseline(dir).converge_if_stale
    changed = MANIFEST.sub("brew \"git\"", "brew \"git\"\n    brew \"gh\"")
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, fetcher: FakeFetcher.new(changed), integration: integration)

    When "the next dev up converges"
    converged = baseline.converge_if_stale

    Then "the refreshed cache drives a new converge"
    converged == true
    integration.installed.map(&:name) == %w[git gh]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a fetch failure falls back to the cached manifest — offline dev up still converges" do
    Given "a cached manifest, a fresh stamp-less host state, and an unreachable repo"
    dir = Dir.mktmpdir("dev-baseline-test-")
    FileUtils.mkdir_p(File.dirname(cache_path(dir)))
    File.write(cache_path(dir), MANIFEST)
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, fetcher: FakeFetcher.new(nil), integration: integration)

    When "converging if stale"
    converged = nil
    _out, err = capture_io { converged = baseline.converge_if_stale }

    Then "the cached copy converges, with a warning about the failed refresh"
    converged == true
    integration.installed.map(&:name) == ["git"]
    err.include?("could not fetch baseline manifest")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a fetch failure with no cache leaves the host nagging, never crashing" do
    Given "no cached manifest and an unreachable repo"
    dir = Dir.mktmpdir("dev-baseline-test-")
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, fetcher: FakeFetcher.new(nil), integration: integration)

    When "converging if stale"
    converged = nil
    _out, err = capture_io { converged = baseline.converge_if_stale }

    Then "nothing to converge from, so the nag stays"
    converged == false
    integration.installed.empty?
    err.include?("could not fetch baseline manifest")
    baseline.message == "host baseline stale — run `dev up`"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "another host's declarations are filtered out of the converge" do
    Given "a manifest gating one entry to the OTHER host OS (the darwin-gated agent CLI case)"
    dir = Dir.mktmpdir("dev-baseline-test-")
    other_host = Dev::Deps.detect_host == "darwin" ? :linux : :darwin
    manifest = <<~MANIFEST
      Dev::Deps.define do
        group :baseline do
          brew "git"
          brew "cursor-cli", cask: true, host: :#{other_host}
        end
      end
    MANIFEST
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, fetcher: FakeFetcher.new(manifest), integration: integration)

    When "converging"
    baseline.converge_if_stale

    Then "only this host's entries install"
    integration.installed.map(&:name) == ["git"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unset baseline_repo turns the whole layer off" do
    Given "no baseline_repo in settings"
    dir = Dir.mktmpdir("dev-baseline-test-")
    fetcher = FakeFetcher.new(MANIFEST)
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, repo: nil, fetcher: fetcher, integration: integration)

    When "checking and converging if stale"
    converged = baseline.converge_if_stale

    Then "quiet, no fetch, nothing to install"
    baseline.message.nil?
    converged == false
    fetcher.fetches.empty?
    integration.installed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge with the default integrations wiring is host-safe on an empty manifest" do
    Given "a manifest declaring nothing, and no factory injected (real Registry wiring)"
    dir = Dir.mktmpdir("dev-baseline-test-")
    saved_env = ENV.delete("DEV_BASELINE_REPO")
    baseline = Dev::Deps::Baseline.new(
      settings: settings_with_baseline_repo(dir, "acme/knowledge"),
      state_dir: File.join(dir, "state"),
      fetcher: FakeFetcher.new("# nothing declared\n"),
    )

    When "converging through the real integrations table"
    baseline.converge_if_stale

    Then "no declarations dispatch, and the converge still stamps"
    File.exist?(stamp_path(dir))

    Cleanup
    ENV["DEV_BASELINE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end
end
