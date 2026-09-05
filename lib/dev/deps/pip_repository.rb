# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fact universe over PyPI's JSON API.
    #
    # Fidelity mirrors LuaRocksRepository: it pins the top-level declared
    # packages; their transitive dependency tree is resolved by pip at install
    # time (PipIntegration), exactly as luarocks resolves a rock's deps on
    # install.
    class PipRepository < Repository
      extend T::Sig

      class ProjectNotFoundError < PackageNotFoundError; end
      class ApiError < StandardError; end

      PYPI_HOST = "https://pypi.org"

      # Report a project's version universe from PyPI's JSON API.
      #
      # One API call yields every published version with its files' SHA256
      # digests — no downloads. Each version's digest is its sdist's, falling
      # back to the first file's; yanked or file-less versions carry nil.
      # Edges stay empty: pip resolves the transitive tree itself at install
      # (PipIntegration), exactly as before. Constraint evaluation moves to
      # Pep440Scheme.
      #
      # @param id [PackageId] name is the PyPI project name
      # @param filter [Hash] unused; the JSON API needs no locator
      # @return [Package]
      # @raise [ProjectNotFoundError] if PyPI has no such project
      # @raise [ApiError] if the API request fails otherwise
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        releases = project_json(id.name)["releases"] || {}
        versions = releases.map do |version, files|
          PackageVersion.new(version: version, digest: release_digest(files))
        end

        Package.new(id: id, versions: versions)
      end

      private

      # GET and parse https://pypi.org/pypi/<name>/json.
      #
      # @param name [String] project name
      # @return [Hash] the parsed project document
      # @raise [ProjectNotFoundError] on 404
      # @raise [ApiError] on any other non-2xx response
      sig { params(name: String).returns(T::Hash[String, T.untyped]) }
      def project_json(name)
        response = get_project(name)
        return JSON.parse(T.must(response.body)) if response.is_a?(Net::HTTPSuccess)
        raise ProjectNotFoundError, "no project named #{name} on PyPI" if response.is_a?(Net::HTTPNotFound)

        raise ApiError, "PyPI API returned #{response.code} for #{name}: #{response.body}"
      end

      # Perform the HTTP request. Isolated so tests can stub the boundary.
      #
      # @param name [String] project name
      # @return [Net::HTTPResponse]
      sig { params(name: String).returns(Net::HTTPResponse) }
      def get_project(name)
        Net::HTTP.get_response(URI("#{PYPI_HOST}/pypi/#{name}/json"))
      end

      # A release's integrity digest: the sdist's SHA256 when one exists
      # (platform-independent), else the first file's, else nil.
      #
      # @param files [Array<Hash>] the release's file objects
      # @return [String, nil]
      sig { params(files: T::Array[T::Hash[String, T.untyped]]).returns(T.nilable(String)) }
      def release_digest(files)
        file = files.find { |f| f["packagetype"] == "sdist" } || files.first
        sha256 = file&.dig("digests", "sha256")
        sha256 ? "SHA256=#{sha256}" : nil
      end
    end
  end
end
