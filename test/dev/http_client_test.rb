# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/http_client"

# HttpClient is the adapter at the HTTP boundary, so the one Net::HTTP call
# it makes is its contract, and what Net::HTTP answers is a real response.
transform!(RSpock::AST::Transformation)
class Dev::HttpClientTest < Minitest::Test
  MANIFEST = "https://ghcr.io/v2/d3mlabs/floor/manifests/ue5.8-3"
  HEADERS = { "Accept" => "application/vnd.oci.image.index.v1+json", "Authorization" => "Bearer t" }.freeze

  test "get returns the status, the headers lower-cased and the body as a Response" do
    Given
    client = Dev::HttpClient.new

    When
    response = client.get(MANIFEST, headers: HEADERS)

    Then "one GET with the headers given; the answer is the value the caller reads"
    1 * Net::HTTP.get_response(URI(MANIFEST), HEADERS) >>
      http_response("200", body: "{}", headers: { "Docker-Content-Digest" => "sha256:abc" })
    response.code == 200
    response.headers["docker-content-digest"] == "sha256:abc"
    response.body == "{}"
  end

  test "get follows a redirect without the Authorization header" do
    Given
    client = Dev::HttpClient.new
    storage = "https://storage.example/blob"

    When
    response = client.get(MANIFEST, headers: HEADERS)

    Then "the registry's token is not shown to the storage host"
    1 * Net::HTTP.get_response(URI(MANIFEST), HEADERS) >> http_response("307", headers: { "Location" => storage })
    1 * Net::HTTP.get_response(URI(storage), { "Accept" => HEADERS["Accept"] }) >> http_response("200", body: "blob")
    response.code == 200
    response.body == "blob"
  end

  test "get hands back a non-success as it is, for the caller's own check" do
    Given
    client = Dev::HttpClient.new

    When
    response = client.get(MANIFEST, headers: {})

    Then
    1 * Net::HTTP.get_response(URI(MANIFEST), {}) >> http_response("403", body: "denied")
    response.code == 403
    response.body == "denied"
  end
end
