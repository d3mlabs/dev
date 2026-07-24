# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "securerandom"
require "shellwords"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for GitHub dependencies (gh integration).
    #
    # Materializes each dep into an immutable version-keyed subdir of its declared
    # install_dir (install_dir/<tag>/, see Integration's version-keyed layout), so
    # distinct locked tags coexist, branch switches never reinstall, and concurrent
    # jobs never overwrite a directory another is mounting. Two shapes:
    #
    # Prebuilt release assets (declared with assets:):
    #   1. Skip when the marker file already records the locked tag (idempotent)
    #   2. Download assets via `gh release download` into a staging dir
    #   3. Verify each asset's SHA256 against the digest locked at resolve time
    #   4. Extract (concatenating split .tar.zst.* archives) and publish
    #
    # Build from source (declared with build:, e.g. stock UE which Epic ships as
    # source only):
    #   1. Skip when the marker file already records the locked tag (idempotent)
    #   2. Fetch the tag's source tarball via `gh api .../tarball` (auth'd, follows
    #      the codeload redirect so private/Epic-gated repos work)
    #   3. Extract, then run the build recipe with the cwd set to the source tree
    #      and $DEV_SOURCE_DIR / $DEV_INSTALL_DIR / $DEV_VERSION in the environment.
    #      The recipe must leave the final artifact in $DEV_INSTALL_DIR (dev creates
    #      it empty); build: :none skips the build and publishes the source as-is.
    #   4. Publish $DEV_INSTALL_DIR (or the source tree for :none)
    #
    # Deliberately bypasses the shared download Cache: artifacts here are
    # multi-gigabyte (the UE engine is ~8GB compressed; a built tree far more), so
    # parking a second copy in ~/.dev/cache would double disk usage for no benefit.
    # The version-keyed install dir plus its marker file is the cache.
    class GhIntegration < Integration
      class DownloadError < StandardError; end
      class IntegrityError < StandardError; end
      class ExtractionError < StandardError; end
      class UnsupportedArchiveError < StandardError; end
      class BuildError < StandardError; end

      MARKER_FILE = ".dev-gh-release"

      # @param repository [Repository]
      # @param cache [Cache]
      # @param project_root [String, Pathname, nil] repo root, used to resolve a
      #   project-relative build: script path (e.g. "bin/build-ue.sh")
      def initialize(repository:, cache:, project_root: nil)
        super(repository: repository, cache: cache)
        @project_root = project_root && Pathname(project_root)
      end

      # Install all gh dependencies.
      #
      # @param dependencies [Array<Dependency>] gh deps to install
      def install_all(dependencies)
        dependencies.each { |dep| install(dep) }
      end

      private

      attr_reader :project_root

      # @param dep [Dependency]
      def install(dep)
        dep.metadata["assets"] ? install_prebuilt(dep) : install_from_source(dep)
      end

      # @param dep [Dependency]
      def install_prebuilt(dep)
        base_dir = Pathname(File.expand_path(dep.metadata["install_dir"]))
        target_dir = versioned_dir(base_dir, dep.version)
        if version_published?(target_dir, MARKER_FILE, dep.version)
          puts ">>> #{dep.name}@#{dep.version} already installed at #{target_dir}"
          publish_current(base_dir, target_dir)
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
        publish_current(base_dir, target_dir)
      ensure
        FileUtils.rm_rf(staging_dir) if staging_dir
      end

      # @param dep [Dependency]
      def install_from_source(dep)
        base_dir = Pathname(File.expand_path(dep.metadata["install_dir"]))
        target_dir = versioned_dir(base_dir, dep.version)
        if version_published?(target_dir, MARKER_FILE, dep.version)
          puts ">>> #{dep.name}@#{dep.version} already installed at #{target_dir}"
          publish_current(base_dir, target_dir)
          return
        end

        staging_dir = new_staging_dir(base_dir)
        source_dir = staging_dir / "source"
        install_dir = staging_dir / "install"
        archive_path = staging_dir / "source.tar.gz"
        FileUtils.mkdir_p(source_dir)
        FileUtils.mkdir_p(install_dir)

        puts ">>> Fetching #{dep.name}@#{dep.version} source from #{dep.metadata["repo"]}"
        download_source(dep, archive_path)
        extract_source(archive_path, source_dir)

        published_dir = build_source(dep, source_dir, install_dir)

        # Stamp the marker inside staging so the published dir is atomically
        # complete: a reader never sees content without a valid marker.
        (published_dir / MARKER_FILE).write(dep.version)
        if publish_version(published_dir, target_dir)
          puts ">>> Installed #{dep.name}@#{dep.version} to #{target_dir}"
        else
          puts ">>> #{dep.name}@#{dep.version} published concurrently at #{target_dir}"
        end
        publish_current(base_dir, target_dir)
      ensure
        FileUtils.rm_rf(staging_dir) if staging_dir
      end

      # Point <install_dir>/current at the just-installed version via a relative
      # symlink, swapped in atomically. Host consumers (e.g. cellbound's
      # build-game.sh via UE_ROOT) reference this stable path without knowing the
      # locked tag; the versioned dirs themselves stay immutable — only this
      # pointer moves, to the most recently installed version.
      #
      # @param base_dir [Pathname] declared install_dir
      # @param target_dir [Pathname] the published version dir
      def publish_current(base_dir, target_dir)
        link = base_dir / "current"
        tmp = base_dir / ".current-#{Process.pid}-#{SecureRandom.hex(4)}"
        File.symlink(target_dir.basename.to_s, tmp.to_s)
        File.rename(tmp.to_s, link.to_s)
      rescue StandardError
        FileUtils.rm_f(tmp.to_s) if tmp
        raise
      end

      # Fetch the tag's source tarball into archive_path. Uses `gh api .../tarball`
      # rather than a bare codeload URL so the request carries gh's auth token and
      # follows the redirect — required for private/Epic-gated repos. Isolated so
      # tests can stub the gh CLI boundary.
      #
      # @param dep [Dependency]
      # @param archive_path [Pathname] destination .tar.gz
      # @raise [DownloadError] if the fetch fails
      def download_source(dep, archive_path)
        success = system(
          "gh", "api", "repos/#{dep.metadata["repo"]}/tarball/#{dep.version}",
          out: archive_path.to_s,
        )
        return if success

        raise DownloadError,
          "gh api tarball failed for #{dep.metadata["repo"]}@#{dep.version}"
      end

      # Extract a GitHub source tarball into source_dir, stripping the single
      # top-level "<repo>-<sha>/" directory GitHub wraps archives in so the tree
      # root (e.g. Setup.sh) lands directly in source_dir.
      #
      # @param archive_path [Pathname]
      # @param source_dir [Pathname]
      # @raise [ExtractionError] if tar fails
      def extract_source(archive_path, source_dir)
        success = system(
          "tar", "-xzf", archive_path.to_s, "-C", source_dir.to_s, "--strip-components=1"
        )
        return if success

        raise ExtractionError, "source extraction failed for #{archive_path}"
      end

      # Produce the directory to publish: the build output for a real recipe, or
      # the source tree itself for header-only deps (build: :none).
      #
      # @param dep [Dependency]
      # @param source_dir [Pathname] extracted source ($DEV_SOURCE_DIR)
      # @param install_dir [Pathname] empty output dir ($DEV_INSTALL_DIR)
      # @return [Pathname] the staging dir to publish as the version dir
      def build_source(dep, source_dir, install_dir)
        if dep.metadata["build"] == "none"
          puts ">>> #{dep.name}@#{dep.version}: header-only, publishing source as-is"
          return source_dir
        end

        puts ">>> Building #{dep.name}@#{dep.version} (#{dep.metadata["build"]})"
        run_build(dep, source_dir, install_dir)
        install_dir
      end

      # Run the build recipe with cwd at the source tree and the dev build
      # contract in the environment. Isolated so tests can stub it.
      #
      # @param dep [Dependency]
      # @param source_dir [Pathname]
      # @param install_dir [Pathname]
      # @raise [BuildError] if the recipe exits non-zero
      def run_build(dep, source_dir, install_dir)
        env = {
          "DEV_SOURCE_DIR" => source_dir.to_s,
          "DEV_INSTALL_DIR" => install_dir.to_s,
          "DEV_VERSION" => dep.version,
        }
        success = system(env, *build_command(dep.metadata["build"]), chdir: source_dir.to_s)
        return if success

        raise BuildError,
          "build failed for #{dep.name}@#{dep.version} (#{dep.metadata["build"]})"
      end

      # Resolve a build: value to a command. A project-relative path to an existing
      # file is run as a script (via bash, so it needs no +x bit); anything else is
      # treated as an inline shell snippet.
      #
      # @param build [String] script path or inline shell
      # @return [Array<String>] argv for system
      def build_command(build)
        script = project_root&.join(build)
        return ["bash", script.to_s] if script&.file?

        ["sh", "-c", build]
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
