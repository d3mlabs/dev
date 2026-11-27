# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/oci_repository"
require "json"

transform!(RSpock::AST::Transformation)
class Dev::Deps::OciRepositoryTest < Minitest::Test
  include SorbetHelper

  FLOOR = "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3"
  MANIFEST_URL = "https://ghcr.io/v2/d3mlabs/unreal-engine-build-base/manifests/ue5.8-3"
  TOKEN_URL = "https://ghcr.io/token?scope=repository%3Ad3mlabs%2Funreal-engine-build-base%3Apull&service=ghcr.io"
  CHALLENGE = 'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:d3mlabs/unreal-engine-build-base:pull"'
  CONFIG_DIGEST = "sha256:#{"c" * 64}".freeze
  CONFIG_URL = "https://ghcr.io/v2/d3mlabs/unreal-engine-build-base/blobs/#{CONFIG_DIGEST}".freeze

  test "find answers the registry's challenge with gh's token and reports the tag as one version whose digest is the manifest's" do
    Given "a private single-platform image behind a bearer challenge"
    auth = gh_auth
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: auth, http: http)

    When
    package = repo.find(Dev::Deps::PackageId.new(integration: :image, name: "snappy-linux", source: FLOOR))

    Then "the tag is the version, the manifest digest the integrity hash, the platform read off the config"
    _ * auth.token >> "gho_secret"
    _ * auth.login >> "jpduchesne"
    1 * http.get(MANIFEST_URL, headers: has_key("Accept")) >> response(401, { "www-authenticate" => CHALLENGE }, "")
    1 * http.get(TOKEN_URL, headers: { "Authorization" => "Basic #{["jpduchesne:gho_secret"].pack("m0")}" }) >>
      response(200, {}, { token: "bearer-1" }.to_json)
    1 * http.get(MANIFEST_URL, headers: has_entry("Authorization", "Bearer bearer-1")) >>
      response(200, { "docker-content-digest" => "sha256:#{"a" * 64}" }, single_manifest)
    1 * http.get(CONFIG_URL, headers: has_entry("Authorization", "Bearer bearer-1")) >>
      response(200, {}, { os: "linux", architecture: "amd64" }.to_json)
    package.versions.size == 1
    version = package.versions.first
    version.version == "ue5.8-3"
    version.digest == "SHA256=#{"a" * 64}"
    version.source == "sha256:#{"a" * 64}"
    version.metadata == { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platforms" => ["linux/amd64"] }
  end

  test "find lists an index's platforms, skipping attestation entries, and needs no config fetch" do
    Given "a multi-arch index served without a challenge"
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: gh_auth, http: http)
    index = {
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests: [
        { digest: "sha256:1", platform: { os: "linux", architecture: "amd64" } },
        { digest: "sha256:2", platform: { os: "linux", architecture: "arm64", variant: "v8" } },
        { digest: "sha256:3", platform: { os: "unknown", architecture: "unknown" } },
      ],
    }.to_json

    When
    package = repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    1 * http.get(MANIFEST_URL, headers: anything) >> response(200, { "docker-content-digest" => "sha256:#{"b" * 64}" }, index)
    package.versions.first.metadata["platforms"] == ["linux/amd64", "linux/arm64/v8"]
    package.versions.first.digest == "SHA256=#{"b" * 64}"
  end

  test "find computes the digest over the manifest bytes when the registry sends no Docker-Content-Digest header" do
    Given
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: gh_auth, http: http)
    body = single_manifest

    When
    package = repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    1 * http.get(MANIFEST_URL, headers: anything) >> response(200, {}, body)
    1 * http.get(CONFIG_URL, headers: anything) >> response(200, {}, { os: "linux", architecture: "amd64" }.to_json)
    package.versions.first.digest == "SHA256=#{Digest::SHA256.hexdigest(body)}"
  end

  test "find raises PackageNotFoundError when the registry has no such tag" do
    Given
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: gh_auth, http: http)

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    1 * http.get(MANIFEST_URL, headers: anything) >> response(404, {}, '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises RegistryError carrying the status and body on any other answer" do
    Given
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: gh_auth, http: http)

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    1 * http.get(MANIFEST_URL, headers: anything) >> response(503, {}, "upstream unavailable\n")
    error = raises(Dev::Deps::OciRepository::RegistryError)
    error.message.include?("HTTP 503")
    error.message.include?("upstream unavailable")
    error.message.include?(MANIFEST_URL)
  end

  test "find raises AccessDeniedError naming the scope to add when the token is refused after the challenge" do
    Given "a token without read:packages"
    auth = gh_auth
    http = http_client
    repo = Dev::Deps::OciRepository.new(auth: auth, http: http)

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    _ * auth.token >> "t"
    _ * auth.login >> "u"
    1 * http.get(MANIFEST_URL, headers: has_key("Accept")) >> response(401, { "www-authenticate" => CHALLENGE }, "")
    1 * http.get(TOKEN_URL, headers: anything) >> response(200, {}, { token: "weak" }.to_json)
    1 * http.get(MANIFEST_URL, headers: has_entry("Authorization", "Bearer weak")) >> response(403, {}, "denied")
    error = raises(Dev::Deps::OciRepository::AccessDeniedError)
    error.message.include?("read:packages")
  end

  test "a source that is not <registry>/<repository>:<tag> is a ReferenceError: #{source.inspect}" do
    Given
    repo = Dev::Deps::OciRepository.new(auth: gh_auth, http: http_client)

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: source))

    Then
    raises Dev::Deps::OciRepository::ReferenceError

    Where
    why | source
    "no registry host: the floor is never a floating Hub name" | "ubuntu:22.04"
    "no tag: nothing to resolve"                             | "ghcr.io/d3mlabs/unreal-engine-build-base"
    "a digest is already resolved; declare the tag"          | "ghcr.io/d3mlabs/unreal-engine-build-base@sha256:abc"
    "no source at all"                                       | nil
  end

  private

  def gh_auth
    typed_mock(Dev::GhAuth)
  end

  def http_client
    typed_mock(Dev::HttpClient)
  end

  def response(code, headers, body)
    Dev::Deps::OciRepository::Response.new(code: code, headers: headers, body: body)
  end

  def single_manifest
    {
      mediaType: "application/vnd.docker.distribution.manifest.v2+json",
      config: { digest: CONFIG_DIGEST },
      layers: [],
    }.to_json
  end
end
