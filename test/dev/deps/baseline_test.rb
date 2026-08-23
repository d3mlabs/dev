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

  def write_manifest(dir, content = MANIFEST)
    path = File.join(dir, "baseline", "dependencies.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def build_baseline(dir, manifest_path, integration: RecordingIntegration.new)
    Dev::Deps::Baseline.new(
      manifest_path: manifest_path,
      state_dir: File.join(dir, "state"),
      integrations_factory: -> { { brew: integration } },
    )
  end

  test "a never-converged host reports the baseline message" do
    Given "a shipped manifest and no stamp on this host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    baseline = build_baseline(dir, write_manifest(dir))

    Expect "the warn-only nag with its remediation"
    baseline.message == "host baseline stale — run `dev up`"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge installs the manifest's declarations and stamps the digest" do
    Given "a stale host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_path = write_manifest(dir)
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, manifest_path, integration: integration)

    When "converging"
    baseline.converge

    Then "the brew dep landed (lockless: no version, constraint as metadata) and the host went quiet"
    integration.installed.map(&:name) == ["git"]
    integration.installed.fetch(0).integration == :brew
    integration.installed.fetch(0).version.nil?
    baseline.message.nil?
    File.read(File.join(dir, "state", "host-baseline", "converged-digest")) ==
      Digest::SHA256.file(manifest_path).hexdigest

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale converges a stale host and reports it did" do
    Given "a stale host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, write_manifest(dir), integration: integration)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then
    converged == true
    integration.installed.map(&:name) == ["git"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale is an O(1) no-op on a warm host" do
    Given "a host already converged on the shipped manifest"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_path = write_manifest(dir)
    build_baseline(dir, manifest_path).converge
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, manifest_path, integration: integration)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then "nothing installed"
    converged == false
    integration.installed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a manifest change (a dev upgrade) makes a converged host stale again" do
    Given "a converged host whose shipped manifest then changes"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_path = write_manifest(dir)
    build_baseline(dir, manifest_path).converge
    File.write(manifest_path, <<~MANIFEST)
      Dev::Deps.define do
        group :baseline do
          brew "git"
          brew "gh"
        end
      end
    MANIFEST
    baseline = build_baseline(dir, manifest_path)

    Expect
    baseline.message == "host baseline stale — run `dev up`"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "another host's declarations are filtered out of the converge" do
    Given "a manifest gating one group to the OTHER host OS (the darwin-gated agent CLI case)"
    dir = Dir.mktmpdir("dev-baseline-test-")
    other_host = Dev::Deps.detect_host == "darwin" ? :linux : :darwin
    manifest_path = write_manifest(dir, <<~MANIFEST)
      Dev::Deps.define do
        group :baseline do
          brew "git"
        end

        group :agent, host: :#{other_host} do
          brew "cursor-cli", cask: true
        end
      end
    MANIFEST
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, manifest_path, integration: integration)

    When "converging"
    baseline.converge

    Then "only this host's entries install"
    integration.installed.map(&:name) == ["git"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a distribution without a shipped manifest is never stale" do
    Given "no manifest at all"
    dir = Dir.mktmpdir("dev-baseline-test-")
    integration = RecordingIntegration.new
    baseline = build_baseline(dir, File.join(dir, "baseline", "dependencies.rb"), integration: integration)

    When "checking and converging if stale"
    converged = baseline.converge_if_stale

    Then "quiet, and nothing to install"
    baseline.message.nil?
    converged == false
    integration.installed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge with the default integrations wiring is host-safe on an empty manifest" do
    Given "a manifest declaring nothing, and no factory injected (real Registry wiring)"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_path = write_manifest(dir, "# nothing declared\n")
    baseline = Dev::Deps::Baseline.new(manifest_path: manifest_path, state_dir: File.join(dir, "state"))

    When "converging through the real integrations table"
    baseline.converge

    Then "no declarations dispatch, and the converge still stamps"
    File.exist?(File.join(dir, "state", "host-baseline", "converged-digest"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the shipped baseline manifest exists and default construction resolves it" do
    Given "a Baseline built entirely from defaults"
    baseline = Dev::Deps::Baseline.new

    Expect "the shipped manifest is part of the distribution"
    Dev::Deps::Baseline::SHIPPED_MANIFEST.file?
    !baseline.nil?

    Cleanup
    nil
  end
end
