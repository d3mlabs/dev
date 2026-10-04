# typed: strict
# frozen_string_literal: true

require "set"
require "pathname"
require "stringio"
require_relative "local_store"
require_relative "lockfile"
require_relative "../container_engine"

module Dev
  module Deps
    # Garbage-collects the host-side caches dev owns, surfaced as `dev cache gc`.
    #
    # dev owns the artifact store (version-keyed trees, content-addressed
    # blobs) and the content-tagged docker images, so it also owns the policy
    # for reclaiming them. A workflow only *schedules* this; it never reaches
    # into the layout itself — nor does this class: trees are enumerated and
    # removed through the store.
    #
    # Size-tiered retention, because the tiers differ by orders of magnitude:
    #
    # - tree versions (multi-GB each: the ~30GB engine, ~15GB server) get a
    #   TIGHT default keep, since a few stale versions dwarf everything else.
    # - orphan staging dirs (from a killed install) are always reclaimable.
    # - docker content tags are pruned down to the live one.
    # - tool caches (bundler's, brew's, pip's download caches in the store)
    #   are left alone unless asked, and then dropped whole: their contents
    #   are the tool's, so dev never prunes inside one, and losing one costs
    #   a re-fetch, never correctness.
    #
    # Two invariants make this safe under concurrency (multiple jobs/branches):
    #
    # - LOCKED versions (current lockfiles) are never evicted — the next build
    #   would just reinstall them.
    # - IN-USE versions (mounted by a running container) are never evicted —
    #   removing a directory a job has mounted would corrupt that job.
    class CacheGc
      extend T::Sig

      DEFAULT_KEEP = 2

      # @param lockfile [Lockfile] source of locked deps (install_dir + version)
      # @param engine   [Dev::ContainerEngine] the invoking user's engine, so
      #   the in-use probes and image pruning see that user's daemon
      # @param store    [ArtifactStore] the store whose trees are reclaimed
      # @param out      [IO, StringIO] progress stream
      sig do
        params(
          lockfile: Lockfile,
          engine: Dev::ContainerEngine,
          store: ArtifactStore,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(lockfile:, engine:, store: LocalStore.new, out: $stdout)
        @lockfile = lockfile
        @engine = engine
        @store = store
        @out = out
      end

      # Reclaim stale install-dir versions and docker content tags.
      #
      # @param keep      [Integer] versions to retain per install_dir (locked and
      #   in-use versions are always retained, even beyond this count)
      # @param image_ref [String, nil] "registry/image" to prune content tags for
      # @param live_tag  [String, nil] the current content tag to never prune
      # @param tool_caches [Boolean] also drop every tool cache whole
      # @return [void]
      sig do
        params(keep: Integer, image_ref: T.nilable(String), live_tag: T.nilable(String), tool_caches: T::Boolean).void
      end
      def gc(keep: DEFAULT_KEEP, image_ref: nil, live_tag: nil, tool_caches: false)
        in_use = running_mount_sources
        gc_install_dirs(keep: keep, in_use: in_use)
        gc_docker(image_ref: image_ref, live_tag: live_tag) if image_ref
        gc_tool_caches if tool_caches
      end

      private

      # Drop every tool cache, each as a unit.
      #
      # @return [void]
      sig { void }
      def gc_tool_caches
        @store.tool_caches.each do |tool|
          @out.puts ">>> gc: removing tool cache #{@store.tool_cache(tool)}"
          @store.remove_tool_cache(tool)
        end
      end

      # Per locked base, keep the locked version + in-use versions + the
      # newest others up to `keep`; remove the rest and any orphan staging dirs.
      #
      # @param keep   [Integer]
      # @param in_use [Set<String>] absolute host paths mounted by live containers
      # @return [void]
      sig { params(keep: Integer, in_use: T::Set[String]).void }
      def gc_install_dirs(keep:, in_use:)
        locked_versions_by_base.each do |base, locked|
          @store.remove_orphan_staging(base).each { |staging| @out.puts ">>> gc: removing orphan staging #{staging}" }
          prune_versions(base, locked: locked, keep: keep, in_use: in_use)
        end
      end

      # @return [Hash{String => Set<String>}] configured install_dir => locked versions
      sig { returns(T::Hash[String, T::Set[String]]) }
      def locked_versions_by_base
        @lockfile.read.each_with_object({}) do |dep, acc|
          dir = dep.metadata && dep.metadata["install_dir"]
          next unless dir && dep.version

          (acc[dir] ||= Set.new) << dep.version
        end
      end

      # @param base   [String] configured install_dir
      # @param locked [Set<String>]
      # @param keep   [Integer]
      # @param in_use [Set<String>]
      sig { params(base: String, locked: T::Set[String], keep: Integer, in_use: T::Set[String]).void }
      def prune_versions(base, locked:, keep:, in_use:)
        # Newest first, so the retained "others" are the most recently used.
        versions = @store.tree_versions(base).sort_by { |v| -File.mtime(tree_path(base, v)).to_f }

        keepers = Set.new(locked)
        versions.each { |v| keepers << v if keepers.size < keep }

        versions.each do |version|
          path = tree_path(base, version).to_s
          next if keepers.include?(version) || mounted?(path, in_use)

          @out.puts ">>> gc: removing #{path}"
          @store.remove_tree(TreeKey.new(base:, version:))
        end
      end

      # @param base [String] configured install_dir
      # @param version [String]
      # @return [Pathname]
      sig { params(base: String, version: String).returns(Pathname) }
      def tree_path(base, version)
        @store.tree_path(TreeKey.new(base:, version:))
      end

      # Whether path is mounted by a live container (exact dir or an ancestor).
      #
      # @param path   [String]
      # @param in_use [Set<String>]
      # @return [Boolean]
      sig { params(path: String, in_use: T::Set[String]).returns(T::Boolean) }
      def mounted?(path, in_use)
        in_use.any? { |source| source == path || source.start_with?("#{path}/") || path.start_with?("#{source}/") }
      end

      # Host paths mounted by every running container, through the injected
      # engine (whose capture is best-effort: a docker failure yields an empty
      # set rather than blocking GC — the locked-version guard still holds).
      #
      # @return [Set<String>]
      sig { returns(T::Set[String]) }
      def running_mount_sources
        ids = @engine.capture(["ps", "-q"]).split("\n").map(&:strip).reject(&:empty?)
        return Set.new if ids.empty?

        sources = @engine.capture(["inspect", "--format", "{{range .Mounts}}{{.Source}}\n{{end}}", *ids])
        Set.new(sources.split("\n").map(&:strip).reject(&:empty?))
      end

      # Remove content-addressed image tags for image_ref except the live tag and
      # any tag backing a running container.
      #
      # @param image_ref [String]
      # @param live_tag  [String, nil]
      sig { params(image_ref: String, live_tag: T.nilable(String)).void }
      def gc_docker(image_ref:, live_tag:)
        tags = @engine.capture(["images", image_ref, "--format", "{{.Repository}}:{{.Tag}}"])
          .split("\n").map(&:strip).reject(&:empty?)
        in_use_images = running_image_refs

        tags.each do |tag|
          next unless tag.include?(":content-")
          next if tag == live_tag || in_use_images.include?(tag)

          @out.puts ">>> gc: removing image #{tag}"
          @engine.run(["rmi", tag], out: File::NULL, err: File::NULL)
        end
      end

      # @return [Set<String>] image refs of running containers
      sig { returns(T::Set[String]) }
      def running_image_refs
        Set.new(@engine.capture(["ps", "--format", "{{.Image}}"]).split("\n").map(&:strip).reject(&:empty?))
      end
    end
  end
end
