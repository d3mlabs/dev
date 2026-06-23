# frozen_string_literal: true

require "set"
require "fileutils"
require "pathname"
require_relative "lockfile"

module Dev
  module Deps
    # Garbage-collects the host-side caches dev owns, surfaced as `dev cache gc`.
    #
    # dev owns the cache *layout* (version-keyed install dirs, content-addressed
    # download cache, content-tagged docker images), so it also owns the policy
    # for reclaiming them. A workflow only *schedules* this; it never reaches
    # into the layout itself.
    #
    # Size-tiered retention, because the tiers differ by orders of magnitude:
    #
    # - install_dir versions (multi-GB each: the ~30GB engine, ~15GB server) get
    #   a TIGHT default keep, since a few stale versions dwarf everything else.
    # - orphan staging dirs (from a killed install) are always reclaimable.
    # - docker content tags are pruned down to the live one.
    #
    # Two invariants make this safe under concurrency (multiple jobs/branches):
    #
    # - LOCKED versions (current lockfiles) are never evicted — the next build
    #   would just reinstall them.
    # - IN-USE versions (mounted by a running container) are never evicted —
    #   removing a directory a job has mounted would corrupt that job.
    class CacheGc
      DEFAULT_KEEP = 2
      STAGING_GLOB = ".staging-*"

      # @param lockfile [Lockfile] source of locked deps (install_dir + version)
      # @param out      [IO] progress stream
      def initialize(lockfile:, out: $stdout)
        @lockfile = lockfile
        @out = out
      end

      # Reclaim stale install-dir versions and docker content tags.
      #
      # @param keep      [Integer] versions to retain per install_dir (locked and
      #   in-use versions are always retained, even beyond this count)
      # @param image_ref [String, nil] "registry/image" to prune content tags for
      # @param live_tag  [String, nil] the current content tag to never prune
      # @return [void]
      def gc(keep: DEFAULT_KEEP, image_ref: nil, live_tag: nil)
        in_use = running_mount_sources
        gc_install_dirs(keep: keep, in_use: in_use)
        gc_docker(image_ref: image_ref, live_tag: live_tag) if image_ref
      end

      private

      # Per install_dir base, keep the locked version + in-use versions + the
      # newest others up to `keep`; remove the rest and any orphan staging dirs.
      #
      # @param keep   [Integer]
      # @param in_use [Set<String>] absolute host paths mounted by live containers
      # @return [void]
      def gc_install_dirs(keep:, in_use:)
        locked_versions_by_base.each do |base, locked|
          next unless Dir.exist?(base)

          remove_orphan_staging(base)
          prune_versions(base, locked: locked, keep: keep, in_use: in_use)
        end
      end

      # @return [Hash{String => Set<String>}] expanded install_dir => locked versions
      def locked_versions_by_base
        @lockfile.read.each_with_object({}) do |dep, acc|
          dir = dep.metadata && dep.metadata["install_dir"]
          next unless dir && dep.version

          (acc[File.expand_path(dir)] ||= Set.new) << dep.version
        end
      end

      # @param base   [String]
      # @param locked [Set<String>]
      # @param keep   [Integer]
      # @param in_use [Set<String>]
      def prune_versions(base, locked:, keep:, in_use:)
        # Newest first, so the retained "others" are the most recently used.
        versions = version_dirs(base).sort_by { |v| -File.mtime(File.join(base, v)).to_f }

        keepers = Set.new(locked)
        versions.each { |v| keepers << v if keepers.size < keep }

        versions.each do |version|
          path = File.join(base, version)
          next if keepers.include?(version) || mounted?(path, in_use)

          @out.puts ">>> gc: removing #{path}"
          FileUtils.rm_rf(path)
        end
      end

      # Immediate version subdirs (excludes staging dirs and marker files).
      #
      # @param base [String]
      # @return [Array<String>] version directory basenames
      def version_dirs(base)
        Dir.children(base).select do |child|
          File.directory?(File.join(base, child)) && !child.start_with?(".staging-")
        end
      end

      # @param base [String]
      def remove_orphan_staging(base)
        Dir.glob(File.join(base, STAGING_GLOB)).each do |staging|
          @out.puts ">>> gc: removing orphan staging #{staging}"
          FileUtils.rm_rf(staging)
        end
      end

      # Whether path is mounted by a live container (exact dir or an ancestor).
      #
      # @param path   [String]
      # @param in_use [Set<String>]
      # @return [Boolean]
      def mounted?(path, in_use)
        in_use.any? { |source| source == path || source.start_with?("#{path}/") || path.start_with?("#{source}/") }
      end

      # Host paths mounted by every running container. Isolated as the docker
      # boundary so tests can stub it. Best-effort: a docker failure yields an
      # empty set rather than blocking GC (the locked-version guard still holds).
      #
      # @return [Set<String>]
      def running_mount_sources
        ids = capture("docker", "ps", "-q").split("\n").map(&:strip).reject(&:empty?)
        return Set.new if ids.empty?

        sources = capture("docker", "inspect", "--format", "{{range .Mounts}}{{.Source}}\n{{end}}", *ids)
        Set.new(sources.split("\n").map(&:strip).reject(&:empty?))
      end

      # Remove content-addressed image tags for image_ref except the live tag and
      # any tag backing a running container.
      #
      # @param image_ref [String]
      # @param live_tag  [String, nil]
      def gc_docker(image_ref:, live_tag:)
        tags = capture("docker", "images", image_ref, "--format", "{{.Repository}}:{{.Tag}}")
          .split("\n").map(&:strip).reject(&:empty?)
        in_use_images = running_image_refs

        tags.each do |tag|
          next unless tag.include?(":content-")
          next if tag == live_tag || in_use_images.include?(tag)

          @out.puts ">>> gc: removing image #{tag}"
          system("docker", "rmi", tag, out: File::NULL, err: File::NULL)
        end
      end

      # @return [Set<String>] image refs of running containers
      def running_image_refs
        Set.new(capture("docker", "ps", "--format", "{{.Image}}").split("\n").map(&:strip).reject(&:empty?))
      end

      # Run a command and capture stdout, returning "" on failure.
      #
      # @return [String]
      def capture(*argv)
        require "open3"
        out, _err, status = Open3.capture3(*argv)
        status.success? ? out : ""
      rescue StandardError
        ""
      end
    end
  end
end
