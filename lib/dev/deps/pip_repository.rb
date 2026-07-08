# frozen_string_literal: true

require "digest"
require "open3"
require "tmpdir"
require_relative "repository"
require_relative "dependency"

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
      class DownloadError < StandardError; end
      class NoVersionError < StandardError; end

      PYTHON = "python3"

      # Resolve a pip package to an exact version + integrity hash.
      #
      # @param id [Hash] identifier with "name", "integration", "group", and an
      #   optional "version" constraint (e.g. ">=2.0", "2.0.5")
      # @return [Dependency]
      # @raise [DownloadError] if pip download fails or yields no artifact
      # @raise [NoVersionError] if the version can't be read from the artifact
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

      # A bare version ("2.0.5") becomes an exact pin ("==2.0.5"); an already-
      # operatored constraint (">=2.0") passes through; blank means unpinned.
      #
      # @param constraint [String, nil]
      # @return [String]
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
      def version_from_filename(filename, _name)
        stem = filename.sub(/\.(?:whl|tar\.gz|tgz|zip)\z/, "")
        stem.split("-").find { |token| token.match?(/\A\d/) }
      end
    end
  end
end
