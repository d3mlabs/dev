# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitRepositoryTest < Minitest::Test
  test "fetch resolves mod to version, hash, and transitive deps" do
    Given "a repository with a stubbed GraphQL response"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "Area Actions",
          "mod_reference" => "AreaActions",
          "versions" => [{
            "id" => "ver1",
            "version" => "2.5.0",
            "game_version" => ">=491125",
            "targets" => [{
              "targetName" => "Windows",
              "hash" => "deadbeef1234567890abcdef1234567890abcdef1234567890abcdef12345678",
              "size" => 500_000,
            }],
            "dependencies" => [
              { "mod_id" => "SML", "condition" => "^3.12.0", "optional" => false },
              { "mod_id" => "OptionalMod", "condition" => ">=1.0", "optional" => true },
            ],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response), is_a?: true)
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching the dependency"
    dep = repo.fetch(
      "name" => "AreaActions",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    dep.name == "AreaActions"
    dep.integration == :ficsit
    dep.group == :app
    dep.version == "2.5.0"
    dep.hash == "SHA256=deadbeef1234567890abcdef1234567890abcdef1234567890abcdef12345678"
    dep.metadata["mod_id"] == "abc123"
    dep.metadata["game_version"] == ">=491125"
    dep.metadata["target"] == "Windows"
    dep.dependencies.size == 1
    dep.dependencies[0][:name] == "SML"
    dep.dependencies[0][:constraint] == "^3.12.0"
  end

  test "fetch uses specified target platform" do
    Given "a mod with multiple targets"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "TestMod",
          "mod_reference" => "TestMod",
          "versions" => [{
            "id" => "ver1",
            "version" => "1.0.0",
            "game_version" => ">=491125",
            "targets" => [
              { "targetName" => "Windows", "hash" => "winhash123", "size" => 100 },
              { "targetName" => "LinuxServer", "hash" => "linuxhash456", "size" => 200 },
            ],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching with target: LinuxServer"
    dep = repo.fetch(
      "name" => "TestMod",
      "integration" => "ficsit",
      "group" => "app",
      "target" => "LinuxServer",
    )

    Then
    dep.hash == "SHA256=linuxhash456"
    dep.metadata["target"] == "LinuxServer"
  end

  test "fetch defaults to Windows target" do
    Given "a mod with only Windows target"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "TestMod",
          "mod_reference" => "TestMod",
          "versions" => [{
            "id" => "ver1",
            "version" => "1.0.0",
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

    When "fetching without specifying target"
    dep = repo.fetch(
      "name" => "TestMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    dep.metadata["target"] == "Windows"
    dep.hash == "SHA256=winhash"
  end

  test "fetch resolves multiple platforms into nested metadata with absolute links" do
    Given "a mod with Windows and LinuxServer targets and relative links"
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

    When "fetching with a platform set including the nil default and LinuxServer"
    dep = repo.fetch(
      "name" => "SML",
      "integration" => "ficsit",
      "group" => "app",
      "platforms" => [nil, "LinuxServer"],
    )

    Then
    dep.version == "3.12.0"
    dep.hash.nil?
    dep.metadata["platforms"]["Windows"]["hash"] == "SHA256=winhash"
    dep.metadata["platforms"]["Windows"]["link"] == "https://api.ficsit.app/v1/version/ver1/Windows/download"
    dep.metadata["platforms"]["LinuxServer"]["hash"] == "SHA256=linuxhash"
    dep.metadata["platforms"]["LinuxServer"]["link"] == "https://api.ficsit.app/v1/version/ver1/LinuxServer/download"
    !dep.metadata.key?("target")
  end

  test "fetch builds the download link from the version id when link is absent" do
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

    When "fetching the LinuxServer platform"
    dep = repo.fetch(
      "name" => "SML",
      "integration" => "ficsit",
      "group" => "integration",
      "platforms" => ["LinuxServer"],
    )

    Then
    dep.metadata["platforms"]["LinuxServer"]["link"] ==
      "https://api.ficsit.app/v1/version/ver1/LinuxServer/download"
  end

  test "fetch raises TargetNotFoundError when a requested platform has no target" do
    Given "a mod with only a Windows target"
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
            "targets" => [{ "targetName" => "Windows", "hash" => "winhash", "size" => 100,
                            "link" => "/v1/version/ver1/Windows/download" }],
            "dependencies" => [],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching a missing LinuxServer platform"
    repo.fetch(
      "name" => "SML",
      "integration" => "ficsit",
      "group" => "integration",
      "platforms" => ["LinuxServer"],
    )

    Then
    raises Dev::Deps::FicsitRepository::TargetNotFoundError
  end

  test "fetch raises ModNotFoundError when mod does not exist" do
    Given "a repository returning null mod data"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = { "data" => { "getModByReference" => nil } }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching a nonexistent mod"
    repo.fetch(
      "name" => "NonExistentMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    raises Dev::Deps::FicsitRepository::ModNotFoundError
  end

  test "fetch raises NoVersionError when mod has no versions" do
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

    When "fetching a mod with no versions"
    repo.fetch(
      "name" => "EmptyMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    raises Dev::Deps::FicsitRepository::NoVersionError
  end

  test "fetch raises ApiError when GraphQL returns errors" do
    Given "a GraphQL error response"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "errors" => [{ "message" => "something went wrong" }],
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching triggers an API error"
    repo.fetch(
      "name" => "BadMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    raises Dev::Deps::FicsitRepository::ApiError
  end

  test "fetch raises ApiError when HTTP request fails" do
    Given "a failing HTTP response"
    repo = Dev::Deps::FicsitRepository.new
    stub_response = stub(code: "500", body: "Internal Server Error")
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(false)
    repo.stubs(:post_graphql).raises(
      Dev::Deps::FicsitRepository::ApiError.new("ficsit.app API returned 500: Internal Server Error")
    )

    When "fetching triggers an HTTP error"
    repo.fetch(
      "name" => "BadMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    raises Dev::Deps::FicsitRepository::ApiError
  end

  test "fetch returns nil hash when no targets exist" do
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

    When "fetching the dependency"
    dep = repo.fetch(
      "name" => "NoTargetMod",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    dep.hash.nil?
    dep.version == "1.0.0"
  end

  test "fetch excludes optional dependencies from transitive list" do
    Given "a mod with both required and optional dependencies"
    repo = Dev::Deps::FicsitRepository.new
    graphql_response = {
      "data" => {
        "getModByReference" => {
          "id" => "abc123",
          "name" => "MixedDeps",
          "mod_reference" => "MixedDeps",
          "versions" => [{
            "id" => "ver1",
            "version" => "1.0.0",
            "game_version" => ">=491125",
            "targets" => [{ "targetName" => "Windows", "hash" => "aaa", "size" => 100 }],
            "dependencies" => [
              { "mod_id" => "SML", "condition" => "^3.12.0", "optional" => false },
              { "mod_id" => "OptionalLib", "condition" => ">=1.0", "optional" => true },
              { "mod_id" => "RequiredLib", "condition" => "^2.0", "optional" => false },
            ],
          }],
        },
      },
    }
    stub_response = stub(body: JSON.generate(graphql_response))
    stub_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:post_graphql).returns(stub_response)

    When "fetching the dependency"
    dep = repo.fetch(
      "name" => "MixedDeps",
      "integration" => "ficsit",
      "group" => "app",
    )

    Then
    dep.dependencies.size == 2
    dep.dependencies.map { |d| d[:name] }.sort == ["RequiredLib", "SML"]
  end
end
