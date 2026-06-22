# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamRepositoryTest < Minitest::Test
  test "fetch uses an explicitly pinned buildid without invoking steamcmd" do
    Given "a declaration with a pinned buildid"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_build_id).raises("steamcmd should not be called")

    When "fetching"
    dep = repo.fetch(
      "name" => "SatisfactoryServer",
      "integration" => "steam",
      "group" => "integration",
      "app" => 1690800,
      "install_dir" => "~/.dev/satisfactory-server",
      "buildid" => "15321746",
      "platforms" => ["LinuxServer"],
    )

    Then
    dep.name == "SatisfactoryServer"
    dep.integration == :steam
    dep.group == :integration
    dep.version == "15321746"
    dep.hash.nil?
    dep.metadata["app"] == "1690800"
    dep.metadata["branch"] == "public"
    dep.metadata["install_dir"] == "~/.dev/satisfactory-server"
    dep.metadata["platform"] == "linux"
  end

  test "fetch resolves the current public buildid via steamcmd when not pinned" do
    Given "no pinned buildid and a stubbed steamcmd resolution"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_build_id).with(app: 1690800, branch: "public").returns("99999")

    When "fetching"
    dep = repo.fetch(
      "name" => "SatisfactoryServer",
      "integration" => "steam",
      "group" => "integration",
      "app" => 1690800,
      "install_dir" => "~/.dev/satisfactory-server",
      "platforms" => ["LinuxServer"],
    )

    Then
    dep.version == "99999"
  end

  test "fetch defaults platform to linux when no group platform is set" do
    Given "a declaration with no platforms"
    repo = Dev::Deps::SteamRepository.new

    When "fetching with a pinned buildid"
    dep = repo.fetch(
      "name" => "SatisfactoryServer",
      "integration" => "steam",
      "group" => "integration",
      "app" => 1690800,
      "install_dir" => "/tmp/server",
      "buildid" => "1",
    )

    Then
    dep.metadata["platform"] == "linux"
  end
end
