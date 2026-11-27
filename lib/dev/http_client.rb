# typed: strict
# frozen_string_literal: true

require "net/http"
require "uri"

module Dev
  # One GET at the HTTP boundary, redirects followed — what a registry
  # adapter needs ("fetch this URL with these headers; what came back?"),
  # without the session protocol Net::HTTP speaks. A redirect is followed
  # without the Authorization header: the credential is the first host's,
  # and a blob read redirects to a storage host that must not see it.
  class HttpClient
    extend T::Sig

    # One response, the shape the boundary returns.
    class Response < T::Struct
      const :code, Integer
      const :headers, T::Hash[String, String]
      const :body, String
    end

    # @param url [String]
    # @param headers [Hash{String => String}]
    # @return [Response]
    sig { params(url: String, headers: T::Hash[String, String]).returns(Response) }
    def get(url, headers:)
      response = Net::HTTP.get_response(URI(url), headers)
      if response.is_a?(Net::HTTPRedirection) && (location = response["location"])
        return get(location, headers: headers.reject { |key, _| key == "Authorization" })
      end

      Response.new(
        code: response.code.to_i,
        headers: response.each_header.to_h { |key, value| [key.downcase, value] },
        body: response.body.to_s,
      )
    end
  end
end
