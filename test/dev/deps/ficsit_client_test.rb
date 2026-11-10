# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_client"
require "json"
require "socket"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitClientTest < Minitest::Test
  # One HTTP exchange as a local server saw it.
  Request = Data.define(:verb, :path, :headers, :body)

  # A server on a free port that answers exactly one request with the given
  # status and body, and keeps what it received. Real sockets, so the
  # request on the wire — the header SMR reads the token from, the
  # multipart layout — is what is asserted on.
  class OneShotServer
    attr_reader :request

    def initialize(status:, body:)
      @socket = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve(status, body) }
    end

    def endpoint
      URI("http://127.0.0.1:#{@socket.addr[1]}/v2/query")
    end

    def join
      @thread.join(5)
      @socket.close
      @request
    end

    private

    def serve(status, body)
      client = @socket.accept
      request_line = client.gets
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.chomp.split(": ", 2)
        headers[name.downcase] = value
      end
      payload = client.read(headers.fetch("content-length").to_i)
      method, path = request_line.split(" ")
      @request = Request.new(verb: method, path:, headers:, body: payload)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  end

  test "query posts the document and variables as JSON, the API key as the raw Authorization header, and returns the data" do
    Given "a server answering a mod"
    server = OneShotServer.new(status: "200 OK", body: JSON.generate({ "data" => { "getModByReference" => { "id" => "mod-1" } } }))
    client = Dev::Deps::FicsitClient.new(endpoint: server.endpoint)

    When
    data = client.query("query GetModId($modReference: ModReference!) { getModByReference(modReference: $modReference) { id } }",
      { modReference: "Snappy" }, token: "smr-key")
    request = server.join

    Then
    data == { "getModByReference" => { "id" => "mod-1" } }
    request.verb == "POST"
    request.path == "/v2/query"
    request.headers["content-type"] == "application/json"
    request.headers["authorization"] == "smr-key"
    JSON.parse(request.body) == {
      "query" => "query GetModId($modReference: ModReference!) { getModByReference(modReference: $modReference) { id } }",
      "variables" => { "modReference" => "Snappy" },
    }
  end

  test "an anonymous query sends no Authorization header" do
    Given
    server = OneShotServer.new(status: "200 OK", body: JSON.generate({ "data" => {} }))

    When
    Dev::Deps::FicsitClient.new(endpoint: server.endpoint).query("query GetMod { x }", {})
    request = server.join

    Then
    !request.headers.key?("authorization")
  end

  test "upload lays the mutation out per the GraphQL multipart request spec: operations, map, then the file part" do
    Given "a server accepting a part"
    server = OneShotServer.new(status: "200 OK", body: JSON.generate({ "data" => { "uploadVersionPart" => true } }))
    client = Dev::Deps::FicsitClient.new(endpoint: server.endpoint)
    document = "mutation UploadVersionPart($modId: ModID!, $versionId: VersionID!, $part: Int!, $file: Upload!) { uploadVersionPart(...) }"

    When
    data = client.upload(document, { modId: "mod-1", versionId: "up-9", part: 3 }, file: "PK\x03\x04bytes".b, filename: "Snappy.zip", token: "smr-key")
    request = server.join

    Then "three parts in order, the file variable null in operations and mapped from the part named 0"
    data == { "uploadVersionPart" => true }
    request.headers["authorization"] == "smr-key"
    request.headers["content-type"].start_with?("multipart/form-data; boundary=")
    boundary = request.headers["content-type"][/boundary=(.+)\z/, 1]
    parts = request.body.split("--#{boundary}").map(&:strip).reject { |part| part.empty? || part == "--" }
    parts.size == 3
    parts[0].start_with?('Content-Disposition: form-data; name="operations"')
    JSON.parse(parts[0].split("\r\n\r\n", 2).last) == {
      "query" => document,
      "variables" => { "modId" => "mod-1", "versionId" => "up-9", "part" => 3, "file" => nil },
    }
    parts[1].start_with?('Content-Disposition: form-data; name="map"')
    JSON.parse(parts[1].split("\r\n\r\n", 2).last) == { "0" => ["variables.file"] }
    parts[2].start_with?('Content-Disposition: form-data; name="0"; filename="Snappy.zip"')
    parts[2].include?("Content-Type: application/octet-stream")
    parts[2].split("\r\n\r\n", 2).last.b == "PK\x03\x04bytes".b
  end

  test "a non-2xx answer is an ApiError carrying the status and body" do
    Given
    server = OneShotServer.new(status: "401 Unauthorized", body: "user not logged in")

    When
    Dev::Deps::FicsitClient.new(endpoint: server.endpoint).query("query GetMod { x }", {}, token: "bad")
    server.join

    Then
    e = raises Dev::Deps::FicsitClient::ApiError
    e.message == "ficsit.app API returned 401: user not logged in"
  end

  test "a GraphQL errors list is an ApiError in SMR's words" do
    Given
    server = OneShotServer.new(status: "200 OK",
      body: JSON.generate({ "errors" => [{ "message" => "mod is not validated" }, { "message" => "you must provide an AI use disclosure" }] }))

    When
    Dev::Deps::FicsitClient.new(endpoint: server.endpoint).query("mutation CreateVersion { x }", {}, token: "key")
    server.join

    Then
    e = raises Dev::Deps::FicsitClient::ApiError
    e.message == "ficsit.app GraphQL error: mod is not validated; you must provide an AI use disclosure"
  end

  test "the production endpoint is SMR's GraphQL API over TLS" do
    Expect
    Dev::Deps::FicsitClient::ENDPOINT == URI("https://api.ficsit.app/v2/query")
    Dev::Deps::FicsitClient::HOST == "https://api.ficsit.app"
  end
end
