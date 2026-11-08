# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "stringio"
require "uri"

module Dev
  module Deps
    # The one HTTP boundary to ficsit.app's GraphQL API (the Satisfactory Mod
    # Repository, `api.ficsit.app/v2/query`), shared by the ficsit
    # integration's two sides: the read side (FicsitRepository#find — an
    # anonymous query) and the write side (the publisher — authenticated
    # mutations, one of them carrying a file part). Transport only: a
    # document and its variables in, the response's `data` out; a non-2xx
    # status or an `errors` member is an ApiError in SMR's own words. No
    # SMR vocabulary (mods, versions, targets) lives here.
    #
    # SMR authenticates with the user's API key as the raw `Authorization`
    # header value — no `Bearer` scheme (`db.UserFromGQLContext` in smr-api
    # reads the header as the session token).
    class FicsitClient
      extend T::Sig

      # The API answered other than 2xx, or answered a GraphQL `errors` list.
      class ApiError < StandardError; end

      # The API host; the GraphQL endpoint and the REST download links
      # (`/v1/version/<id>/<target>/download`) share it.
      HOST = "https://api.ficsit.app"
      ENDPOINT = T.let(URI("#{HOST}/v2/query"), URI::Generic)

      # The variable the upload mutations take their file under
      # (`uploadVersionPart(…, file: Upload!)`); the GraphQL multipart
      # request spec maps the form's file part onto it.
      FILE_VARIABLE = "file"
      FILE_PART = "0"

      Variables = T.type_alias { T::Hash[Symbol, T.untyped] }
      ResponseData = T.type_alias { T::Hash[String, T.untyped] }

      # @param endpoint [URI::Generic] the GraphQL endpoint (tests point it at a local server)
      sig { params(endpoint: URI::Generic).void }
      def initialize(endpoint: ENDPOINT)
        @endpoint = endpoint
      end

      # Run a query or a mutation with JSON variables.
      #
      # @param document [String] the GraphQL document
      # @param variables [Hash{Symbol => Object}]
      # @param token [String, nil] the user's API key, for a document behind `@isLoggedIn`
      # @return [Hash] the response's `data`
      # @raise [ApiError]
      sig { params(document: String, variables: Variables, token: T.nilable(String)).returns(ResponseData) }
      def query(document, variables, token: nil)
        request = Net::HTTP::Post.new(@endpoint.path)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ query: document, variables: })
        send_request(request, token)
      end

      # Run a mutation carrying one file, laid out per the GraphQL multipart
      # request spec: an `operations` field (the document and its variables,
      # the file variable null), a `map` field pointing the file part at
      # that variable, then the file part itself.
      #
      # @param document [String] a mutation taking `$file: Upload!`
      # @param variables [Hash{Symbol => Object}] the other variables
      # @param file [String] the bytes to send as the file
      # @param filename [String] what the part is named
      # @param token [String] the user's API key
      # @return [Hash] the response's `data`
      # @raise [ApiError]
      sig { params(document: String, variables: Variables, file: String, filename: String, token: String).returns(ResponseData) }
      def upload(document, variables, file:, filename:, token:)
        operations = JSON.generate({ query: document, variables: variables.merge(FILE_VARIABLE.to_sym => nil) })
        map = JSON.generate({ FILE_PART => ["variables.#{FILE_VARIABLE}"] })
        request = Net::HTTP::Post.new(@endpoint.path)
        request.set_form(
          [
            ["operations", operations],
            ["map", map],
            [FILE_PART, StringIO.new(file), { filename:, content_type: "application/octet-stream" }],
          ],
          "multipart/form-data",
        )
        send_request(request, token)
      end

      private

      # Send one request and read its `data`.
      #
      # @param request [Net::HTTP::Post]
      # @param token [String, nil]
      # @return [Hash]
      # @raise [ApiError]
      sig { params(request: Net::HTTP::Post, token: T.nilable(String)).returns(ResponseData) }
      def send_request(request, token)
        request["Authorization"] = token if token
        http = Net::HTTP.new(T.must(@endpoint.host), @endpoint.port)
        http.use_ssl = @endpoint.scheme == "https"
        response = http.request(request)
        raise ApiError, "ficsit.app API returned #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(T.must(response.body))
        if parsed.key?("errors")
          messages = parsed["errors"].map { |error| error["message"] }.join("; ")
          raise ApiError, "ficsit.app GraphQL error: #{messages}"
        end

        parsed.fetch("data")
      end
    end
  end
end
