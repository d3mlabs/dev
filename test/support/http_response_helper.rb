# typed: false
# frozen_string_literal: true

require "net/http"
require "stringio"

# Builds the Net::HTTPResponse an HTTP collaborator answers with, so a test
# of how a class reads that answer (`is_a?(Net::HTTPSuccess)`, `code`,
# `body`) runs against the real type rather than a double whose `is_a?`
# is stubbed into shape:
#
#   1 * repo.get_project("requests") >> http_response("200 OK", json)
#   1 * repo.get_project("nope") >> http_response("404 Not Found", "Not Found")
#
# Net::HTTPResponse has no public constructor for an already-read
# response, so this builds one the way Net::HTTP does: from wire bytes.
# `read_new` picks the subclass from the status (200 OK is a Net::HTTPOK,
# 404 Not Found a Net::HTTPNotFound).
module HttpResponseHelper
  # @param status_line [String] status code and reason, e.g. "200 OK"
  # @param body [String] the response body
  # @param headers [Hash{String => String}] extra response headers
  # @return [Net::HTTPResponse] the subclass matching the status, body read
  def http_response(status_line, body, headers = {})
    header_lines = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    raw = "HTTP/1.1 #{status_line}\r\nContent-Length: #{body.bytesize}\r\n#{header_lines}\r\n#{body}"
    io = Net::BufferedIO.new(StringIO.new(raw))
    Net::HTTPResponse.read_new(io).tap { |response| response.reading_body(io, true) {} }
  end
end
