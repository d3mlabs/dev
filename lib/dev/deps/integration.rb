# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"

module Dev
  module Deps
    # Lifecycle handler for a dependency type.
    #
    # Accepts a Repository and Cache via DI at construction. Receives all
    # dependencies for its type at once via install_all — handles per-dep
    # install plus any batch artifacts (e.g. deps.cmake).
    class Integration
      # @param repository [Repository] source adapter for this integration type
      # @param cache      [Cache]      shared download cache
      def initialize(repository:, cache:)
        @repository = repository
        @cache = cache
      end

      # Install all dependencies of this integration type.
      #
      # @param dependencies [Array<Dependency>] all deps for this integration type
      def install_all(dependencies)
        raise NotImplementedError, "#{self.class}#install_all must be implemented"
      end

      private

      attr_reader :repository, :cache

      # --- version-keyed, content-addressed install layout (gh, steam) -------
      #
      # Large host-installed deps (the ~30GB engine, the ~15GB server) live in
      # a version-keyed subdir of their declared install_dir:
      #
      #   <install_dir>/<version>/…            # immutable, one per locked version
      #
      # This brings them under the same content-addressed principle as the
      # download cache: distinct locked versions coexist instead of overwriting,
      # so switching branches never reinstalls and concurrent jobs on different
      # versions never collide. dev's mount resolution
      # (BuildContainer.resolve_versioned_volumes) maps the configured volume
      # onto the right versioned subdir, so a job mounts an immutable directory
      # for its whole life.

      # The immutable directory a given version is published to.
      #
      # @param base_dir [Pathname] declared install_dir
      # @param version  [String]   locked version (gh tag / steam buildid)
      # @return [Pathname]
      def versioned_dir(base_dir, version)
        Pathname(base_dir) / version
      end

      # A unique staging dir on the same filesystem as the published versions,
      # so publishing is a cheap atomic rename and a crashed/killed run can
      # never corrupt a published version (it only ever leaves orphan staging).
      #
      # @param base_dir [Pathname]
      # @return [Pathname]
      def new_staging_dir(base_dir)
        Pathname("#{base_dir}/.staging-#{Process.pid}-#{SecureRandom.hex(4)}")
      end

      # Whether a version is fully published: its dir exists with a marker file
      # recording the expected version. The marker is written into staging and
      # only becomes visible via the atomic publish, so a half-built version is
      # never seen as installed.
      #
      # @param dir          [Pathname] versioned dir
      # @param marker_file  [String]   marker basename
      # @param version      [String]   expected version
      # @return [Boolean]
      def version_published?(dir, marker_file, version)
        marker = dir / marker_file
        marker.file? && marker.read.strip == version
      end

      # Atomically publish a fully-built staging dir as the version dir.
      #
      # First writer wins: File.rename onto an existing (non-empty) version dir
      # raises, which we treat as "another job already published this version"
      # and leave the existing dir untouched — we never rm_rf a live directory a
      # concurrent reader may have mounted. The caller's ensure block removes
      # the leftover staging in that case.
      #
      # Relies on staging and the version dir living on one filesystem (both
      # under base_dir), so the rename is atomic rather than a cross-device copy.
      #
      # @param staging   [Pathname] fully-built, marker-stamped staging dir
      # @param versioned [Pathname] destination version dir
      # @return [Boolean] true if this call published, false if another won
      def publish_version(staging, versioned)
        FileUtils.mkdir_p(versioned.dirname)
        File.rename(staging.to_s, versioned.to_s)
        true
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR
        false
      end
    end
  end
end
