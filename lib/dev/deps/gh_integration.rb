# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "shellwords"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for GitHub release dependencies (gh integration).
    #
    # Installs each release artifact into its declared install_dir on the host:
    #
    # 1. Skip when the marker file already records the locked tag (idempotent)
    # 2. Download assets via `gh release download` into a staging dir
    # 3. Verify each asset's SHA256 against the digest locked at resolve time
    # 4. Extract (concatenating split .tar.zst.* archives) and move into place
    #
    # Deliberately bypasses the shared download Cache: artifacts here are
    # multi-gigabyte (the UE engine is ~8GB compressed), so parking a second
    # copy in ~/.dev/cache would double disk usage for no benefit. The
    # version-keyed install dir plus its marker file is the cache.
    #
    # Each release installs into an immutable version-keyed subdir
    # (install_dir/<tag>/, see Integration's version-keyed layout), so distinct
    # locked tags coexist, branch switches never reinstall, and concurrent jobs
    # never overwrite a directory another is mounting.
    class GhIntegration < Integration
      class DownloadError < StandardError; end
      class IntegrityError < StandardError; end
      class ExtractionError < StandardError; end
      class UnsupportedArchiveError < StandardError; end

      MARKER_FILE = ".dev-gh-release"

      # Install all gh dependencies.
      #
      # @param dependencies [Array<Dependency>] gh deps to install
      def install_all(dependencies)
        dependencies.each { |dep| install(dep) }
      end

      private

      # @param dep [Dependency]
      def install(dep)
        base_dir = Pathname(File.expand_path(dep.metadata["install_dir"]))
        target_dir = versioned_dir(base_dir, dep.version)
        if version_published?(target_dir, MARKER_FILE, dep.version)
          puts ">>> #{dep.name}@#{dep.version} already installed at #{target_dir}"
          return
        end

        # Staging lives next to the version dirs so the publish is a cheap
        # same-filesystem rename; a crashed run leaves published versions intact.
        staging_dir = new_staging_dir(base_dir)
        archives_dir = staging_dir / "archives"
        extracted_dir = staging_dir / "extracted"
        FileUtils.mkdir_p(archives_dir)
        FileUtils.mkdir_p(extracted_dir)

        puts ">>> Downloading #{dep.name}@#{dep.version} from #{dep.metadata["repo"]}"
        download_assets(dep, archives_dir)
        verify_assets(dep, archives_dir)

        puts ">>> Extracting #{dep.name}@#{dep.version}"
        extract_archives(archives_dir, extracted_dir)

        # Stamp the marker inside staging so the published dir is atomically
        # complete: a reader never sees content without a valid marker.
        (extracted_dir / MARKER_FILE).write(dep.version)
        if publish_version(extracted_dir, target_dir)
          puts ">>> Installed #{dep.name}@#{dep.version} to #{target_dir}"
        else
          puts ">>> #{dep.name}@#{dep.version} published concurrently at #{target_dir}"
        end
      ensure
        FileUtils.rm_rf(staging_dir) if staging_dir
      end

      # Download the locked release assets. Isolated so tests can stub the
      # gh CLI boundary.
      #
      # @param dep [Dependency]
      # @param archives_dir [Pathname] destination for downloaded assets
      # @raise [DownloadError] if gh release download fails
      def download_assets(dep, archives_dir)
        success = system(
          "gh", "release", "download", dep.version,
          "--repo", dep.metadata["repo"],
          "--pattern", dep.metadata["asset_pattern"],
          "--dir", archives_dir.to_s,
        )
        return if success

        raise DownloadError,
              "gh release download failed for #{dep.metadata["repo"]}@#{dep.version}"
      end

      # Verify downloaded files against the digests locked at resolve time.
      # Assets locked without a digest (older releases) are skipped.
      #
      # @param dep [Dependency]
      # @param archives_dir [Pathname]
      # @raise [DownloadError] if a locked asset is missing from the download
      # @raise [IntegrityError] if a digest does not match
      def verify_assets(dep, archives_dir)
        dep.metadata["assets"].each do |asset|
          path = archives_dir / asset["name"]
          raise DownloadError, "expected asset #{asset["name"]} was not downloaded" unless path.file?

          expected = asset["sha256"]
          next unless expected

          actual = Digest::SHA256.file(path).hexdigest
          next if actual == expected

          raise IntegrityError,
                "SHA256 mismatch for #{asset["name"]}: expected #{expected}, got #{actual}"
        end
      end

      # Extract all downloaded archives into extracted_dir. Split archives
      # (name.tar.zst.00, .01, ...) are grouped by base name and concatenated
      # in part order before decompression.
      #
      # @param archives_dir [Pathname]
      # @param extracted_dir [Pathname]
      def extract_archives(archives_dir, extracted_dir)
        groups = archives_dir.children.select(&:file?).group_by { |path| archive_base_name(path) }
        groups.each do |base_name, parts|
          extract_zstd_tarball(base_name, parts.sort, extracted_dir)
        end
      end

      # Strip a numeric split suffix: "x.tar.zst.01" → "x.tar.zst".
      #
      # @param path [Pathname]
      # @return [String]
      def archive_base_name(path)
        path.basename.to_s.sub(/\.\d+\z/, "")
      end

      # Decompress a (possibly split) zstd tarball into dest_dir via
      # `cat parts | zstd -d | tar -x` — the same pipeline the Satisfactory
      # modding docs prescribe for the engine archives.
      #
      # @param base_name [String] logical archive name (for error messages)
      # @param parts [Array<Pathname>] archive parts in concatenation order
      # @param dest_dir [Pathname] extraction destination
      # @raise [UnsupportedArchiveError] for non-zstd archives
      # @raise [ExtractionError] if the pipeline fails
      def extract_zstd_tarball(base_name, parts, dest_dir)
        unless base_name.end_with?(".tar.zst")
          raise UnsupportedArchiveError,
                "unsupported archive #{base_name} — only .tar.zst[.NN] is supported"
        end

        pipeline = "cat #{parts.map(&:to_s).shelljoin} | zstd -d | " \
                   "tar -xf - -C #{dest_dir.to_s.shellescape}"
        success = system("sh", "-c", pipeline)
        return if success

        raise ExtractionError, "extraction failed for #{base_name}"
      end
    end
  end
end
