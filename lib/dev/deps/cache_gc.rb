# typed: strict
# frozen_string_literal: true

require "set"
require "pathname"
require "stringio"
require_relative "local_store"
require_relative "lockfile"
require_relative "tree_integrations"
require_relative "../container_engine"
require_relative "../environment_image"
require_relative "../prefix_volumes"

module Dev
  module Deps
    # Garbage-collects the host-side caches dev owns, surfaced as `dev cache gc`.
    #
    # dev owns the artifact store (version-keyed trees, content-addressed
    # blobs) and the lock's docker images, so it also owns the policy
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

      # @param lockfile [Lockfile] source of locked deps (tree identity + version)
      # @param engine   [Dev::ContainerEngine] the invoking user's engine, so
      #   the in-use probes and image pruning see that user's daemon
      # @param store    [ArtifactStore] the store whose trees are reclaimed
      # @param out      [IO, StringIO] progress stream
      # @param prefix_volumes [Dev::PrefixVolumes] the engine's Linuxbrew
      #   prefix volumes, whose stale ones gc reclaims
      sig do
        params(
          lockfile: Lockfile,
          engine: Dev::ContainerEngine,
          store: ArtifactStore,
          out: T.any(IO, StringIO),
          prefix_volumes: Dev::PrefixVolumes,
        ).void
      end
      def initialize(lockfile:, engine:, store: LocalStore.new, out: $stdout, prefix_volumes: Dev::PrefixVolumes.new(engine:))
        @lockfile = lockfile
        @engine = engine
        @store = store
        @out = out
        @prefix_volumes = prefix_volumes
      end

      # Reclaim stale tree versions and the images the lock no longer names.
      #
      # @param keep      [Integer] versions to retain per tree base (locked and
      #   in-use versions are always retained, even beyond this count)
      # @param images    [Array<Dev::EnvironmentImage>] the lock's image pins —
      #   the live set; every other tag of their repositories is stale
      # @param tool_caches [Boolean] also drop every tool cache whole
      # @return [void]
      sig { params(keep: Integer, images: T::Array[Dev::EnvironmentImage], tool_caches: T::Boolean).void }
      def gc(keep: DEFAULT_KEEP, images: [], tool_caches: false)
        in_use = running_mount_sources
        gc_trees(keep: keep, in_use: in_use)
        gc_docker(images: images)
        gc_prefix_volumes
        gc_tool_caches if tool_caches
      end

      private

      # Drop the Linuxbrew prefix volumes nothing will mount again — a host
      # user's that is gone, Linux's bare `dev-linuxbrew` from before the
      # per-user split — unless a container from before still mounts one:
      # that container is its checkout's `dev container up` to recreate,
      # and the volume goes on the gc after.
      #
      # @return [void]
      sig { void }
      def gc_prefix_volumes
        @prefix_volumes.stale.each do |volume|
          reason = volume.user ? "no host user #{volume.user}" : "no host user"
          if volume.mounted_by.empty?
            @out.puts ">>> gc: removing prefix volume #{volume.name} (#{reason})"
            @prefix_volumes.remove!(volume)
          else
            @out.puts ">>> gc: keeping prefix volume #{volume.name} (#{reason}) — mounted by #{volume.mounted_by.join(", ")} " \
                      "(dev container up there recreates it)"
          end
        end
      end

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
      def gc_trees(keep:, in_use:)
        locked_versions_by_base.each do |base, locked|
          @store.remove_orphan_staging(base).each { |staging| @out.puts ">>> gc: removing orphan staging #{staging}" }
          prune_versions(base, locked: locked, keep: keep, in_use: in_use)
        end
      end

      # The lock's tree deps grouped by where their integration places them:
      # one base per identity, however many names the lock gives it.
      #
      # @return [Hash{String => Set<String>}] tree base => locked versions
      sig { returns(T::Hash[String, T::Set[String]]) }
      def locked_versions_by_base
        @lockfile.read.each_with_object({}) do |dep, acc|
          integration = TREE_INTEGRATIONS[dep.integration]
          next unless integration && dep.version

          (acc[integration.tree_key(dep).base] ||= Set.new) << dep.version
        end
      end

      # @param base   [String] tree base
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

      # @param base [String] tree base
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

      # Remove every tag of each pinned image's repository that is not the
      # lock's ref and backs no running container. The lock is the live set
      # (one digest tag per lock change, ~5 GB each) and the repository is
      # the project's own, so nothing another project owns is in scope; a
      # project pinning no image asks docker nothing.
      #
      # @param images [Array<Dev::EnvironmentImage>] the lock's image pins
      sig { params(images: T::Array[Dev::EnvironmentImage]).void }
      def gc_docker(images:)
        return if images.empty?

        in_use_images = running_image_refs
        images.each do |image|
          tags = @engine.capture(["images", image.repository, "--format", "{{.Repository}}:{{.Tag}}"])
            .split("\n").map(&:strip).reject(&:empty?)
          tags.each do |tag|
            next if tag == image.ref || in_use_images.include?(tag)

            @out.puts ">>> gc: removing image #{tag}"
            @engine.run(["rmi", tag], out: File::NULL, err: File::NULL)
          end
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
