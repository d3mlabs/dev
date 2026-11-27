# typed: false
# frozen_string_literal: true

require "net/http"
require "stringio"

# Real Net::HTTPResponse values for the classes that read one. How a class
# reads its collaborator's answer — `is_a?(Net::HTTPSuccess)`, `code`,
# `body`, a header — is the behaviour under test, so the answer is a real
# response of the status's own class (Net::HTTPOK, Net::HTTPNotFound, …),
# parsed from the wire the way Net::HTTP parses one.
module HttpResponses
  # @param code [String, Integer] the status code; decides the response class
  # @param body [String]
  # @param headers [Hash{String => String}]
  # @return [Net::HTTPResponse] an instance of the class for `code`, body read
  def http_response(code, body: "", headers: {})
    wire = +"HTTP/1.1 #{code} #{Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).name.delete_prefix("Net::HTTP")}\r\n"
    headers.each { |name, value| wire << "#{name}: #{value}\r\n" }
    wire << "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    socket = Net::BufferedIO.new(StringIO.new(wire))
    response = Net::HTTPResponse.read_new(socket)
    response.reading_body(socket, true) {}
    response
  end
end
