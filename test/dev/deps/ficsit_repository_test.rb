# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitRepositoryTest < Minitest::Test
  test "find reports every published version with its universe facts" do
    Given "a mod with two versions on ficsit.app"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "Area Actions",
          "mod_reference" => "AreaActions",
          "versions" => [
            {
              "id" => "ver2",
              "version" => "2.5.0",
              "game_version" => ">=491125",
              "targets" => [{
                "targetName" => "Windows",
                "hash" => "deadbeef",
                "size" => 500_000,
                "link" => "/v1/version/ver2/Windows/download",
              }],
              "dependencies" => [
                { "mod_id" => "SML", "condition" => "^3.12.0", "optional" => false },
                { "mod_id" => "OptionalMod", "condition" => ">=1.0", "optional" => true },
              ],
            },
            {
              "id" => "ver1",
              "version" => "2.4.0",
              "game_version" => ">=400000",
              "targets" => [{ "targetName" => "Windows", "hash" => "cafebabe", "size" => 400_000 }],
              "dependencies" => [],
            },
          ],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :ficsit, name: "AreaActions"))

    Then "the whole universe is reported, facts attached"
    package.versions.map(&:version) == ["2.5.0", "2.4.0"]
    latest = package.version("2.5.0")
    latest.platforms == ["Windows"]
    latest.digest == "SHA256=deadbeef"
    latest.artifacts["Windows"].uri == "https://api.ficsit.app/v1/version/ver2/Windows/download"
    latest.artifacts["Windows"].digest == "SHA256=deadbeef"
    latest.dependencies == [Dev::Deps::DependencyEdge.new(name: "SML", constraint: "^3.12.0")]
    latest.metadata["mod_id"] == "abc123"
    latest.metadata["game_version"] == ">=491125"
    latest.metadata["target"] == "Windows"
    package.version("2.4.0").digest == "SHA256=cafebabe"
  end

  test "find with a platforms filter nests per-platform install facts" do
    Given "a mod with Windows and LinuxServer targets"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "SML",
          "mod_reference" => "SML",
          "versions" => [{
            "id" => "ver1",
            "version" => "3.12.0",
            "game_version" => ">=491125",
            "targets" => [
              { "targetName" => "Windows", "hash" => "winhash", "size" => 100,
                "link" => "/v1/version/ver1/Windows/download" },
              { "targetName" => "LinuxServer", "hash" => "linuxhash", "size" => 200,
                "link" => "/v1/version/ver1/LinuxServer/download" },
            ],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding with the nil default and LinuxServer requested"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :ficsit, name: "SML"),
      filter: { "platforms" => [nil, "LinuxServer"] },
    )

    Then "install facts nest per platform and the top-level digest is nil"
    version = package.version("3.12.0")
    version.digest.nil?
    version.metadata["platforms"]["Windows"]["hash"] == "SHA256=winhash"
    version.metadata["platforms"]["Windows"]["link"] == "https://api.ficsit.app/v1/version/ver1/Windows/download"
    version.metadata["platforms"]["LinuxServer"]["hash"] == "SHA256=linuxhash"
    !version.metadata.key?("target")
  end

  test "find omits a requested platform this version does not publish" do
    Given "a mod publishing only a Windows target"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "SML",
          "mod_reference" => "SML",
          "versions" => [{
            "id" => "ver1",
            "version" => "3.12.0",
            "game_version" => ">=491125",
            "targets" => [{ "targetName" => "Windows", "hash" => "winhash", "size" => 100 }],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding with LinuxServer requested"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :ficsit, name: "SML"),
      filter: { "platforms" => ["LinuxServer"] },
    )

    Then "the block simply lacks the platform — disqualifying is the Resolver's call"
    version = package.version("3.12.0")
    version.metadata["platforms"] == {}
    version.platforms == ["Windows"]
  end

  test "find raises ModNotFoundError, a PackageNotFoundError, for unknown mods" do
    Given "a repository returning null mod data"
    repo = Dev::Deps::FicsitRepository.new
    stub_response = stub(body: JSON.generate({ "data" => { "getModByReference" => nil } }))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding a nonexistent mod"
    repo.find(Dev::Deps::PackageId.new(integration: :ficsit, name: "NonExistentMod"))

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find reports a mod with no versions as an empty package" do
    Given "a mod with empty versions"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "EmptyMod",
          "mod_reference" => "EmptyMod",
          "versions" => [],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :ficsit, name: "EmptyMod"))

    Then "an empty universe is a fact, not an error"
    package.empty?
  end

  test "find builds the artifact link from the version id when link is absent" do
    Given "a target without a link field"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "SML",
          "mod_reference" => "SML",
          "versions" => [{
            "id" => "ver1",
            "version" => "3.12.0",
            "game_version" => ">=491125",
            "targets" => [{ "targetName" => "LinuxServer", "hash" => "linuxhash", "size" => 200 }],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding with the LinuxServer platform requested"
    package = repo.find(
      Dev::Deps::PackageId.new(integration: :ficsit, name: "SML"),
      filter: { "platforms" => ["LinuxServer"] },
    )

    Then "the link falls back to the /v1/version/<id>/<target>/download shape"
    package.version("3.12.0").metadata["platforms"]["LinuxServer"]["link"] ==
      "https://api.ficsit.app/v1/version/ver1/LinuxServer/download"
  end

  test "find reports a targetless version with a nil digest" do
    Given "a mod version with no targets"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "NoTargetMod",
          "mod_reference" => "NoTargetMod",
          "versions" => [{
            "id" => "ver1",
            "version" => "1.0.0",
            "game_version" => ">=491125",
            "targets" => [],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :ficsit, name: "NoTargetMod"))

    Then "no published bytes, no integrity fact"
    package.version("1.0.0").digest.nil?
  end

  test "find raises ApiError when GraphQL returns errors" do
    Given "a GraphQL error response"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = { "errors" => [{ "message" => "something went wrong" }] }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "finding triggers an API error"
    repo.find(Dev::Deps::PackageId.new(integration: :ficsit, name: "BadMod"))

    Then
    raises Dev::Deps::FicsitRepository::ApiError
  end
end
