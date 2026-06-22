# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_integration"
require "dev/deps/cache"
require "dev/deps/dependency"
require "tmpdir"

# SteamIntegration with the SteamCMD provisioning boundary replaced by writing a
# fake appmanifest. Everything else (skip/marker idempotency, buildid
# verification) runs for real against the filesystem.
class FixtureSteamIntegration < Dev::Deps::SteamIntegration
  attr_reader :provision_count

  def initialize(manifest_build:, **kwargs)
    super(**kwargs)
    @manifest_build = manifest_build
    @provision_count = 0
  end

  private

  def provision(dep, server_dir)
    @provision_count += 1
    manifest = server_dir / "steamapps" / "appmanifest_#{dep.metadata["app"]}.acf"
    FileUtils.mkdir_p(manifest.dirname)
    manifest.write(<<~ACF)
      "AppState"
      {
        "appid"  "#{dep.metadata["app"]}"
        "buildid"  "#{@manifest_build}"
      }
    ACF
  end
end unless defined?(FixtureSteamIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamIntegrationTest < Minitest::Test
  def build_dependency(install_dir, build_id: "15321746")
    Dev::Deps::Dependency.new(
      name: "SatisfactoryServer", integration: :steam, group: :integration,
      version: build_id, hash: nil,
      metadata: { "app" => "1690800", "branch" => "public",
                  "install_dir" => install_dir, "platform" => "linux" },
    )
  end

  def build_integration(dir, manifest_build:)
    FixtureSteamIntegration.new(
      manifest_build: manifest_build,
      repository: nil,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )
  end

  test "install_all provisions the depot, verifies the build, and writes the marker" do
    Given "a steam dependency and a stubbed provisioner"
    dir = Dir.mktmpdir("dev-steam-int-test-")
    install_dir = File.join(dir, "satisfactory-server")
    dep = build_dependency(install_dir, build_id: "15321746")
    integration = build_integration(dir, manifest_build: "15321746")

    When "installing"
    integration.install_all([dep])

    Then
    integration.provision_count == 1
    File.read(File.join(install_dir, ".dev-steam-build")) == "15321746"
    File.exist?(File.join(install_dir, "install", "steamapps", "appmanifest_1690800.acf"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips when the marker already records the locked build" do
    Given "an install dir with a matching marker"
    dir = Dir.mktmpdir("dev-steam-int-test-")
    install_dir = File.join(dir, "satisfactory-server")
    FileUtils.mkdir_p(install_dir)
    File.write(File.join(install_dir, ".dev-steam-build"), "15321746")
    dep = build_dependency(install_dir, build_id: "15321746")
    integration = build_integration(dir, manifest_build: "15321746")

    When "installing again"
    integration.install_all([dep])

    Then
    integration.provision_count == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all reprovisions when the locked build changes" do
    Given "an install dir marked with an older build"
    dir = Dir.mktmpdir("dev-steam-int-test-")
    install_dir = File.join(dir, "satisfactory-server")
    FileUtils.mkdir_p(install_dir)
    File.write(File.join(install_dir, ".dev-steam-build"), "15000000")
    dep = build_dependency(install_dir, build_id: "15321746")
    integration = build_integration(dir, manifest_build: "15321746")

    When "installing the new build"
    integration.install_all([dep])

    Then
    integration.provision_count == 1
    File.read(File.join(install_dir, ".dev-steam-build")) == "15321746"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises BuildMismatchError when the installed build differs from the lock" do
    Given "a provisioner that installs a different build than locked"
    dir = Dir.mktmpdir("dev-steam-int-test-")
    install_dir = File.join(dir, "satisfactory-server")
    dep = build_dependency(install_dir, build_id: "15321746")
    integration = build_integration(dir, manifest_build: "15999999")

    When "installing"
    integration.install_all([dep])

    Then
    raises Dev::Deps::SteamIntegration::BuildMismatchError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises ProvisionError when no appmanifest is produced" do
    Given "a provisioner that writes nothing"
    dir = Dir.mktmpdir("dev-steam-int-test-")
    install_dir = File.join(dir, "satisfactory-server")
    dep = build_dependency(install_dir)
    integration = Class.new(Dev::Deps::SteamIntegration) do
      def provision(_dep, _server_dir) = nil
    end.new(
      repository: nil,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "installing"
    integration.install_all([dep])

    Then
    raises Dev::Deps::SteamIntegration::ProvisionError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
