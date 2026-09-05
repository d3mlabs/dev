# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamRepositoryTest < Minitest::Test
  test "find reports the pinned buildid as a singleton universe" do
    Given "a declaration with a pinned buildid"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_build_id).raises("steamcmd should not be called")

    When "finding with the pin as locator"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer"),
      filter: {
        "app" => 1690800,
        "install_dir" => "~/.dev/satisfactory-server",
        "buildid" => "15321746",
        "platforms" => ["LinuxServer"],
      },
    )

    Then "one version — the buildid — carrying the install facts, no digest"
    package.versions.map(&:version) == ["15321746"]
    version = package.version("15321746")
    version.digest.nil?
    version.metadata == {
      "app" => "1690800",
      "branch" => "public",
      "install_dir" => "~/.dev/satisfactory-server",
      "platform" => "linux",
    }
  end

  test "find resolves the current branch buildid via steamcmd when not pinned" do
    Given "no pinned buildid and a stubbed steamcmd resolution"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_build_id).with(app: 1690800, branch: "public").returns("99999")

    When "finding"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer"),
      filter: { "app" => 1690800, "install_dir" => "/tmp/server" },
    )

    Then
    package.versions.map(&:version) == ["99999"]
  end

  test "find defaults platform to linux when no group platform is set" do
    Given "a declaration with no platforms"
    repo = Dev::Deps::SteamRepository.new

    When "finding with a pinned buildid"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer"),
      filter: { "app" => 1690800, "install_dir" => "/tmp/server", "buildid" => "1" },
    )

    Then
    package.version("1").metadata["platform"] == "linux"
  end
end
