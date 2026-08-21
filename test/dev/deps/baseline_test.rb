# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/baseline"
require "dev/deps/lockfile"
require "dev/deps/dependency"
require "digest"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::BaselineTest < Minitest::Test
  # A shipped-baseline-shaped dir: a manifest plus the lock generated from it
  # (manifest digest recorded, like update_lock! does).
  def build_shipped_dir(dir)
    manifest_dir = File.join(dir, "baseline")
    FileUtils.mkdir_p(manifest_dir)
    manifest = File.join(manifest_dir, "dependencies.rb")
    File.write(manifest, <<~MANIFEST)
      Dev::Deps.define do
        group :baseline do
          brew "git"
        end
      end
    MANIFEST
    Dev::Deps::Lockfile.new(dir: manifest_dir).lock(
      [Dev::Deps::Dependency.new(
        name: "git", integration: :brew, group: :baseline, version: "2.51.0", hash: nil, metadata: {},
      )],
      manifest_digest: Digest::SHA256.file(manifest).hexdigest,
    )
    manifest_dir
  end

  # Stands in for DependencyInstaller at the factory seam: records the
  # env/host each install ran for, touches nothing on the host.
  class RecordingInstaller
    attr_reader :installs

    def initialize
      @installs = []
    end

    def install(env:, host:)
      @installs << { env: env, host: host }
    end
  end

  # Stands in for Resolver at update_lock!'s injection seam.
  class CannedResolver
    def resolve(_declarations)
      [Dev::Deps::Dependency.new(
        name: "git", integration: :brew, group: :baseline, version: "2.51.0", hash: nil, metadata: {},
      )]
    end
  end

  def build_baseline(dir, manifest_dir, installer: RecordingInstaller.new)
    Dev::Deps::Baseline.new(
      manifest_dir: manifest_dir,
      state_dir: File.join(dir, "state"),
      installer_factory: ->(_lockfile, _integrations) { installer },
    )
  end

  test "a never-converged host reports the baseline message" do
    Given "a shipped lock and no stamp on this host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    baseline = build_baseline(dir, build_shipped_dir(dir))

    Expect "the warn-only nag with its remediation"
    baseline.message == "host baseline stale — run `dev up`"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge installs for the detected env and host, then stamps" do
    Given "a stale host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    installer = RecordingInstaller.new
    baseline = build_baseline(dir, build_shipped_dir(dir), installer: installer)

    When "converging"
    baseline.converge

    Then "one filtered install ran and the host went quiet"
    installer.installs == [{ env: Dev::Deps.detect_env, host: Dev::Deps.detect_host }]
    baseline.message.nil?
    File.exist?(File.join(dir, "state", "host-baseline", "installed-digest"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale converges a stale host and reports it did" do
    Given "a stale host"
    dir = Dir.mktmpdir("dev-baseline-test-")
    installer = RecordingInstaller.new
    baseline = build_baseline(dir, build_shipped_dir(dir), installer: installer)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then
    converged == true
    installer.installs.size == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge_if_stale is an O(1) no-op on a warm host" do
    Given "a host already converged on the shipped lock"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_dir = build_shipped_dir(dir)
    build_baseline(dir, manifest_dir).converge
    installer = RecordingInstaller.new
    baseline = build_baseline(dir, manifest_dir, installer: installer)

    When "converging if stale"
    converged = baseline.converge_if_stale

    Then "nothing installed"
    converged == false
    installer.installs.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a shipped lock change (a dev upgrade) makes a converged host stale again" do
    Given "a converged host whose shipped lock then changes"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_dir = build_shipped_dir(dir)
    build_baseline(dir, manifest_dir).converge
    Dev::Deps::Lockfile.new(dir: manifest_dir).lock(
      [Dev::Deps::Dependency.new(
        name: "gh", integration: :brew, group: :baseline, version: "2.83.0", hash: nil, metadata: {},
      )],
    )
    baseline = build_baseline(dir, manifest_dir)

    Expect
    baseline.message == "host baseline stale — run `dev up`"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "converge with the default installer wiring is host-safe on an empty distribution" do
    Given "a manifest dir with no lock, and no installer injected (real wiring)"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_dir = File.join(dir, "baseline")
    FileUtils.mkdir_p(manifest_dir)
    baseline = Dev::Deps::Baseline.new(manifest_dir: manifest_dir, state_dir: File.join(dir, "state"))

    When "converging through the real DependencyInstaller"
    baseline.converge

    Then "an empty lock read dispatches nothing and no stamp is written (no digest to record)"
    !File.exist?(File.join(dir, "state", "host-baseline", "installed-digest"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a distribution without a shipped lock is never stale" do
    Given "a manifest dir with no lock at all"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_dir = File.join(dir, "baseline")
    FileUtils.mkdir_p(manifest_dir)
    installer = RecordingInstaller.new
    baseline = build_baseline(dir, manifest_dir, installer: installer)

    When "checking and converging if stale"
    converged = baseline.converge_if_stale

    Then "quiet, and nothing to install"
    baseline.message.nil?
    converged == false
    installer.installs.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "update_lock! resolves the manifest and writes the digest-stamped lock" do
    Given "a manifest dir without a lock"
    dir = Dir.mktmpdir("dev-baseline-test-")
    manifest_dir = File.join(dir, "baseline")
    FileUtils.mkdir_p(manifest_dir)
    manifest = File.join(manifest_dir, "dependencies.rb")
    File.write(manifest, <<~MANIFEST)
      Dev::Deps.define do
        group :baseline do
          brew "git"
        end
      end
    MANIFEST
    baseline = build_baseline(dir, manifest_dir)

    When "updating the lock through an injected resolver"
    baseline.update_lock!(resolver: CannedResolver.new)

    Then "the lock exists, carries the manifest digest, and round-trips the dep"
    lockfile = Dev::Deps::Lockfile.new(dir: manifest_dir)
    lockfile.manifest_digest == Digest::SHA256.file(manifest).hexdigest
    lockfile.read.map(&:name) == ["git"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the shipped baseline carries its manifest and committed lock" do
    Given "the distribution's own baseline dir"
    shipped = Dev::Deps::Baseline::SHIPPED_DIR

    Expect "manifest and lock both ship (the lock is committed, not generated on hosts)"
    shipped.join("dependencies.rb").file?
    shipped.join("deps.lock").file?

    Cleanup
    nil
  end
end
