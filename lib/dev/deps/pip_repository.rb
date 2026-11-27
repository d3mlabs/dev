# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "declarations"
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
      # PEP 440's exact-version operator, which a pin's source is spelled with.
      EXACT_REQUIREMENT = "=="

      # Report a project's version universe from PyPI's JSON API: the
      # releases pip has a file to install from.
      #
      # One API call yields every published version with its files' SHA256
      # digests — no downloads. A release with no files, or none that is
      # not yanked (PEP 592), is outside the universe: pip never picks one
      # for a requirement, and a lock naming it would not install. Each
      # version's digest is its sdist's, falling back to the first file's,
      # among the files pip would consider. Each version's source is the
      # requirement pip installs exactly it by, `name==version`. Edges stay
      # empty: pip resolves the transitive tree itself at install
      # (PipIntegration). Constraint evaluation is Pep440Scheme's, which
      # is where a pre-release is kept out unless asked for.
      #
      # pip's one exception — a `==` requirement still installs a yanked
      # release, with a warning — is deliberately not mirrored: a lock dev
      # writes is a fresh choice, and the yank says not to make it. A pin
      # the lock already carries installs by its `name==version` source
      # regardless, as pip allows.
      #
      # @param id [PackageId] name is the PyPI project name
      # @return [Package]
      # @raise [ProjectNotFoundError] if PyPI has no such project
      # @raise [ApiError] if the API request fails otherwise
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        releases = project_json(id.name)["releases"] || {}
        versions = releases.filter_map do |version, files|
          installable = installable_files(files)
          next if installable.empty?

          PackageVersion.new(
            version: version,
            digest: release_digest(installable),
            source: "#{id.name}#{EXACT_REQUIREMENT}#{version}",
            declarations: Declarations::ToolOwned.new,
          )
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
        response = Net::HTTP.get_response(URI("#{PYPI_HOST}/pypi/#{name}/json"))
        return JSON.parse(T.must(response.body)) if response.is_a?(Net::HTTPSuccess)
        raise ProjectNotFoundError, "no project named #{name} on PyPI" if response.is_a?(Net::HTTPNotFound)

        raise ApiError, "PyPI API returned #{response.code} for #{name}: #{response.body}"
      end

      # The files pip would install a release from: the ones not yanked.
      # PyPI yanks per file (PEP 592); a release is yanked when all of its
      # files are, and a partly yanked one is still installable from the rest.
      #
      # @param files [Array<Hash>] the release's file objects
      # @return [Array<Hash>] the files not yanked
      sig { params(files: T::Array[T::Hash[String, T.untyped]]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def installable_files(files)
        files.reject { |file| file["yanked"] == true }
      end

      # A release's integrity digest: the sdist's SHA256 when one exists
      # (platform-independent), else the first file's, else nil when the
      # file publishes no SHA256.
      #
      # @param files [Array<Hash>] the release's installable file objects, at least one
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
