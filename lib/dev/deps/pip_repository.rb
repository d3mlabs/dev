# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "open3"
require "sorbet-runtime"
require "tmpdir"
require "uri"
require_relative "dependency"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Resolves a pip package to an exact version + SHA256 by downloading just
    # that package (no transitive deps) with pip and hashing the artifact.
    #
    # Fidelity mirrors LuaRocksRepository: it pins the top-level declared
    # packages; their transitive dependency tree is resolved by pip at install
    # time (PipIntegration), exactly as luarocks resolves a rock's deps on
    # install. Resolution uses whatever python3 is on PATH — update-deps runs on
    # the author's host, before the project venv necessarily exists.
    class PipRepository < Repository
      extend T::Sig

      class DownloadError < StandardError; end
      class NoVersionError < StandardError; end
      class ProjectNotFoundError < PackageNotFoundError; end
      class ApiError < StandardError; end

      PYTHON = "python3"
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

      # Resolve a pip package to an exact version + integrity hash.
      #
      # @param id [Hash] identifier with "name", "integration", "group", and an
      #   optional "version" constraint (e.g. ">=2.0", "2.0.5")
      # @return [Dependency]
      # @raise [DownloadError] if pip download fails or yields no artifact
      # @raise [NoVersionError] if the version can't be read from the artifact
      sig { params(id: T::Hash[String, T.untyped]).returns(Dependency) }
      def fetch(id)
        name = id["name"]
        spec = "#{name}#{normalize_constraint(id["version"])}"
        artifact = download_artifact(spec)
        version = version_from_filename(File.basename(artifact), name)
        raise NoVersionError, "could not determine version for #{name} from #{File.basename(artifact)}" if version.nil?

        Dependency.new(
          name: name,
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version,
          hash: "SHA256=#{Digest::SHA256.file(artifact).hexdigest}",
          metadata: {},
        )
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

      # A bare version ("2.0.5") becomes an exact pin ("==2.0.5"); an already-
      # operatored constraint (">=2.0") passes through; blank means unpinned.
      #
      # @param constraint [String, nil]
      # @return [String]
      sig { params(constraint: T.nilable(String)).returns(String) }
      def normalize_constraint(constraint)
        value = constraint.to_s.strip
        return "" if value.empty?

        value.match?(/\A[<>=~!]/) ? value : "==#{value}"
      end

      # Download exactly one artifact (the best match for this host) into a temp
      # dir. --no-deps keeps it to the single top-level package.
      #
      # @param spec [String] pip requirement specifier (e.g. "totalsegmentator>=2.0")
      # @return [String] path to the downloaded wheel/sdist
      sig { params(spec: String).returns(String) }
      def download_artifact(spec)
        dir = Dir.mktmpdir("dev_pip_")
        _out, err, status = Open3.capture3(PYTHON, "-m", "pip", "download", "--no-deps", "--dest", dir, spec)
        raise DownloadError, "pip download #{spec} failed: #{err}" unless status.success?

        artifact = Dir[File.join(dir, "*")].reject { |path| File.directory?(path) }.min
        raise DownloadError, "pip download #{spec} produced no artifact" if artifact.nil?

        artifact
      end

      # Read the version from a wheel/sdist filename. Both formats put the
      # version as the first digit-leading, dash-delimited token after the
      # (possibly multi-token) distribution name:
      #   totalsegmentator-2.0.5-py3-none-any.whl -> "2.0.5"
      #   TotalSegmentator-2.0.5.tar.gz           -> "2.0.5"
      #
      # @param filename [String]
      # @param _name    [String] declared package name (kept for signature clarity)
      # @return [String, nil]
      sig { params(filename: String, _name: String).returns(T.nilable(String)) }
      def version_from_filename(filename, _name)
        stem = filename.sub(/\.(?:whl|tar\.gz|tgz|zip)\z/, "")
        stem.split("-").find { |token| token.match?(/\A\d/) }
      end
    end
  end
end
