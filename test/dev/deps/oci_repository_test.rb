# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/oci_repository"
require "json"
require "net/http"

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
    repo = Dev::Deps::OciRepository.new(auth: gh_auth(token: "gho_secret", login: "jpduchesne"))
    repo.expects(:get).with(MANIFEST_URL, headers: has_key("Accept"))
        .returns(response(401, { "www-authenticate" => CHALLENGE }, ""))
    repo.expects(:get).with(TOKEN_URL, headers: { "Authorization" => "Basic #{["jpduchesne:gho_secret"].pack("m0")}" })
        .returns(response(200, {}, { token: "bearer-1" }.to_json))
    repo.expects(:get).with(MANIFEST_URL, headers: has_entry("Authorization", "Bearer bearer-1"))
        .returns(response(200, { "docker-content-digest" => "sha256:#{"a" * 64}" }, single_manifest))
    repo.expects(:get).with(CONFIG_URL, headers: has_entry("Authorization", "Bearer bearer-1"))
        .returns(response(200, {}, { os: "linux", architecture: "amd64" }.to_json))

    When
    package = repo.find(Dev::Deps::PackageId.new(integration: :image, name: "snappy-linux", source: FLOOR))

    Then "the tag is the version, the manifest digest the integrity hash, the platform read off the config"
    package.versions.size == 1
    version = package.versions.first
    version.version == "ue5.8-3"
    version.digest == "SHA256=#{"a" * 64}"
    version.metadata == { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platforms" => ["linux/amd64"] }
  end

  test "find lists an index's platforms, skipping attestation entries, and needs no config fetch" do
    Given "a multi-arch index served without a challenge"
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)
    index = {
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests: [
        { digest: "sha256:1", platform: { os: "linux", architecture: "amd64" } },
        { digest: "sha256:2", platform: { os: "linux", architecture: "arm64", variant: "v8" } },
        { digest: "sha256:3", platform: { os: "unknown", architecture: "unknown" } },
      ],
    }.to_json
    repo.expects(:get).with(MANIFEST_URL, headers: anything)
        .returns(response(200, { "docker-content-digest" => "sha256:#{"b" * 64}" }, index))

    When
    package = repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    package.versions.first.metadata["platforms"] == ["linux/amd64", "linux/arm64/v8"]
    package.versions.first.digest == "SHA256=#{"b" * 64}"
  end

  test "find computes the digest over the manifest bytes when the registry sends no Docker-Content-Digest header" do
    Given
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)
    body = single_manifest
    repo.expects(:get).with(MANIFEST_URL, headers: anything).returns(response(200, {}, body))
    repo.expects(:get).with(CONFIG_URL, headers: anything).returns(response(200, {}, { os: "linux", architecture: "amd64" }.to_json))

    Expect
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR)).versions.first.digest ==
      "SHA256=#{Digest::SHA256.hexdigest(body)}"
  end

  test "find raises PackageNotFoundError when the registry has no such tag" do
    Given
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)
    repo.expects(:get).with(MANIFEST_URL, headers: anything).returns(response(404, {}, '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'))

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises RegistryError carrying the status and body on any other answer" do
    Given
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)
    repo.expects(:get).with(MANIFEST_URL, headers: anything).returns(response(503, {}, "upstream unavailable\n"))

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    error = raises(Dev::Deps::OciRepository::RegistryError)
    error.message.include?("HTTP 503")
    error.message.include?("upstream unavailable")
    error.message.include?(MANIFEST_URL)
  end

  test "get is one Net::HTTP GET over TLS, the answer flattened to code, lower-cased headers and body" do
    Given "the HTTP boundary, faked"
    http = mock("http")
    http.expects(:request).with { |req| req.is_a?(Net::HTTP::Get) && req["Authorization"] == "Bearer b" }
      .returns(http_response(Net::HTTPOK, "200", { "Docker-Content-Digest" => "sha256:abc" }, "{}"))
    Net::HTTP.expects(:start).with("ghcr.io", 443, use_ssl: true).yields(http)
      .returns(http_response(Net::HTTPOK, "200", { "Docker-Content-Digest" => "sha256:abc" }, "{}"))

    When
    result = Dev::Deps::OciRepository.new(auth: gh_auth).send(:get, MANIFEST_URL, headers: { "Authorization" => "Bearer b" })

    Then
    result.code == 200
    result.headers["docker-content-digest"] == "sha256:abc"
    result.body == "{}"
  end

  test "get follows a redirect without carrying the registry's Authorization to the storage host" do
    Given "a blob read that redirects to storage"
    storage = "https://storage.example/blob?sig=1"
    redirect = http_response(Net::HTTPFound, "302", { "Location" => storage }, "")
    registry_http = mock("registry")
    registry_http.expects(:request).returns(redirect)
    storage_http = mock("storage")
    storage_http.expects(:request).with { |req| req["Authorization"].nil? && req["Accept"] == "*/*" }
      .returns(http_response(Net::HTTPOK, "200", {}, "blob"))
    Net::HTTP.expects(:start).with("ghcr.io", 443, use_ssl: true).yields(registry_http).returns(redirect)
    Net::HTTP.expects(:start).with("storage.example", 443, use_ssl: true).yields(storage_http)
      .returns(http_response(Net::HTTPOK, "200", {}, "blob"))

    When
    result = Dev::Deps::OciRepository.new(auth: gh_auth)
      .send(:get, CONFIG_URL, headers: { "Authorization" => "Bearer b", "Accept" => "*/*" })

    Then
    result.code == 200
    result.body == "blob"
  end

  test "find raises AccessDeniedError naming the scope to add when the token is refused after the challenge" do
    Given "a token without read:packages"
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)
    repo.expects(:get).with(MANIFEST_URL, headers: has_key("Accept")).returns(response(401, { "www-authenticate" => CHALLENGE }, ""))
    repo.expects(:get).with(TOKEN_URL, headers: anything).returns(response(200, {}, { token: "weak" }.to_json))
    repo.expects(:get).with(MANIFEST_URL, headers: has_entry("Authorization", "Bearer weak")).returns(response(403, {}, "denied"))

    When
    repo.find(Dev::Deps::PackageId.new(integration: :image, name: "x", source: FLOOR))

    Then
    error = raises(Dev::Deps::OciRepository::AccessDeniedError)
    error.message.include?("read:packages")
  end

  test "a source that is not <registry>/<repository>:<tag> is a ReferenceError: #{source.inspect}" do
    Given
    repo = Dev::Deps::OciRepository.new(auth: gh_auth)

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

  def gh_auth(token: "t", login: "u")
    auth = typed_mock(Dev::GhAuth)
    auth.stubs(token: token, login: login)
    auth
  end

  def response(code, headers, body)
    Dev::Deps::OciRepository::Response.new(code: code, headers: headers, body: body)
  end

  # A real Net::HTTPResponse of the given class, body pre-read.
  def http_response(klass, code, headers, body)
    resp = klass.new("1.1", code, klass.name.split("::").last)
    headers.each { |key, value| resp[key] = value }
    resp.instance_variable_set(:@body, body)
    resp.instance_variable_set(:@read, true)
    resp
  end

  def single_manifest
    {
      mediaType: "application/vnd.docker.distribution.manifest.v2+json",
      config: { digest: CONFIG_DIGEST },
      layers: [],
    }.to_json
  end
end
