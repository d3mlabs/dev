# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require_relative "../deps"
require_relative "cache"
require_relative "dependency"
require_relative "registry"

module Dev
  module Deps
    # The host baseline layer (plans#26): the org-invariant tools every
    # d3mlabs host needs (git, gh, rbenv, shadowenv, the Cursor agent CLI via
    # the upstream cursor-cli cask), declared in a manifest that ships INSIDE
    # dev's distribution (share/baseline/) rather than in any project repo —
    # upgrading dev is what changes the baseline.
    #
    # Deliberately lockless: every baseline entry is a Homebrew name, and
    # brew installs by name — the baseline is *convergence toward a tool
    # set*, not version pinning, so a resolved lockfile would record versions
    # nothing enforces. The O(1) staleness check is therefore a digest of
    # the manifest itself against a per-host stamp under XDG:
    #
    #   - `dev up` converges a stale baseline as its first step (and is the
    #     only remediation),
    #   - every other command surfaces staleness as a warn-only nag via
    #     DependencyService#guard! — the baseline never blocks, even in CI.
    class Baseline
      # The shipped manifest, relative to this file (lib/dev/deps/ → repo or
      # libexec root) — the installed location under brew, same resolution
      # as Plan::Templates::BUNDLE_FILE.
      SHIPPED_MANIFEST = Pathname(File.expand_path(File.join(__dir__, "..", "..", "..", "share", "baseline", "dependencies.rb")))

      STALE_MESSAGE = "host baseline stale — run `dev up`"

      STAMP_FILE = "converged-digest"

      # @param manifest_path [Pathname, String] the baseline manifest (the
      #   shipped one by default)
      # @param state_dir [Pathname, String] host state root — XDG data home
      #   like the learnings cache, NOT ~/.dev/state: project stamps are
      #   per-checkout working state; this is host-layer state
      # @param integrations_factory [#call] () → {Symbol => Integration};
      #   the install seam, injectable so tests never touch the host
      def initialize(manifest_path: SHIPPED_MANIFEST, state_dir: default_state_dir, integrations_factory: nil)
        @manifest_path = Pathname(manifest_path)
        @state_dir = Pathname(state_dir)
        @integrations_factory = integrations_factory ||
          -> { Registry.host_integrations(project_root: @manifest_path.dirname, cache: Cache.new) }
      end

      # The warn-only nag for a stale host, nil when converged. A
      # distribution without a shipped manifest has nothing to converge and
      # is never stale.
      #
      # @return [String, nil]
      def message
        stale? ? STALE_MESSAGE : nil
      end

      # Install the manifest's declarations (filtered to this host OS) and
      # stamp the host converged. Stamping only happens after a fully-
      # successful install, so a crashed run keeps nagging.
      #
      # @return [void]
      def converge
        integrations = @integrations_factory.call
        host_dependencies.group_by(&:integration).each do |type, dependencies|
          integrations.fetch(type).install_all(dependencies)
        end
        stamp!
      end

      # The O(1)-guarded converge `dev up` runs first: one digest comparison
      # on a warm host, a full converge on a stale one.
      #
      # @return [Boolean] whether a converge ran
      def converge_if_stale
        return false unless stale?

        converge
        true
      end

      private

      # @return [Boolean] whether the manifest digest drifted from the stamp
      def stale?
        return false unless @manifest_path.file?

        manifest_digest != stamped_digest
      end

      # The manifest's declarations as installable Dependencies, minus other
      # hosts' entries (e.g. the darwin-gated agent CLI on a Linux target
      # host). No resolve step: the constraint hash IS the install metadata
      # — brew converges by name, so there is no resolved version to carry.
      #
      # @return [Array<Dependency>]
      def host_dependencies
        host = Deps.detect_host
        declarations.filter_map do |declaration|
          next if declaration.host && declaration.host.to_s != host

          Dependency.new(
            name: declaration.name,
            integration: declaration.integration,
            group: declaration.group,
            version: nil,
            hash: nil,
            metadata: declaration.constraint,
          )
        end
      end

      # @return [Array<DependencyDeclaration>] the manifest's declarations
      def declarations
        Deps.reset!
        Kernel.load(@manifest_path.to_s)
        Deps.last_config&.declarations || []
      end

      # @return [String] SHA-256 hex of the manifest content
      def manifest_digest
        Digest::SHA256.file(@manifest_path.to_s).hexdigest
      end

      # @return [String, nil] the last converged manifest digest on this host
      def stamped_digest
        stamp_path.file? ? stamp_path.read.strip : nil
      end

      # Record the just-converged manifest digest.
      #
      # @return [void]
      def stamp!
        FileUtils.mkdir_p(stamp_path.dirname)
        stamp_path.write(manifest_digest)
      end

      # Fixed host-singular stamp path: the baseline is per-host, so its
      # stamp must not vary with the manifest's path (which moves on every
      # brew upgrade of dev).
      #
      # @return [Pathname]
      def stamp_path
        @state_dir / "host-baseline" / STAMP_FILE
      end

      # @return [String] $XDG_DATA_HOME/dev (the learnings-cache precedent)
      def default_state_dir
        data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
        File.join(data_home, "dev")
      end
    end
  end
end
