# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/steam_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SteamRepositoryTest < Minitest::Test
  def id
    Dev::Deps::PackageId.new(integration: :steam, name: "SatisfactoryServer", source: "1690800")
  end

  test "find reports every branch's current buildid, one version per branch" do
    Given "an app with public and experimental branch tips"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches)
                       .with(app: "1690800")
                       .returns({ "public" => "15321746", "experimental" => "15400000" })

    When "finding"
    package = repo.find(id)

    Then "each branch tip is a version, its branch riding metadata as a fact"
    package.versions.map(&:version).sort == ["15321746", "15400000"]
    public_tip = package.version("15321746")
    public_tip.digest.nil?
    public_tip.metadata == { "app" => "1690800", "branch" => "public" }
    package.version("15400000").metadata["branch"] == "experimental"
  end

  test "find claims self-contained declarations — SteamCMD delivers the whole tree" do
    Given "a single-branch app"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches).returns({ "public" => "1" })

    When "finding"
    package = repo.find(id)

    Then
    package.version("1").declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises PackageNotFoundError when no branch reports a buildid" do
    Given "an app steamcmd reports no branches for"
    repo = Dev::Deps::SteamRepository.new
    Dev::Deps::SteamCmd.stubs(:resolve_branches).returns({})

    When "finding"
    repo.find(id)

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end
end
