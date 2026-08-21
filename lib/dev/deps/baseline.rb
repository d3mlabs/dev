# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "../deps"
require_relative "cache"
require_relative "dependency_installer"
require_relative "lockfile"
require_relative "registry"
require_relative "resolver"
require_relative "staleness"

module Dev
  module Deps
    # The host baseline layer (plans#26): the org-invariant tools every
    # d3mlabs host needs (git, gh, rbenv, shadowenv, the Cursor agent CLI),
    # declared in a manifest that ships INSIDE dev's distribution
    # (share/baseline/) rather than in any project repo — upgrading dev is
    # what changes the baseline.
    #
    # The lock is resolved in dev's own repo (`bin/update-baseline.rb`) and
    # committed, so hosts only ever install from the shipped pin — they never
    # resolve. Convergence state is one stamp per host under a fixed key
    # (Staleness with state_key "host-baseline"), giving the same O(1)
    # digest staleness check projects get:
    #
    #   - `dev up` converges a stale baseline as its first step (and is the
    #     only remediation),
    #   - every other command surfaces staleness as a warn-only nag via
    #     DependencyService#guard! — the baseline never blocks, even in CI.
    class Baseline
      # The shipped manifest+lock, relative to this file (lib/dev/deps/ →
      # repo or libexec root) — the installed location under brew, same
      # resolution as Plan::Templates::BUNDLE_FILE.
      SHIPPED_DIR = Pathname(File.expand_path(File.join(__dir__, "..", "..", "..", "share", "baseline")))

      # Fixed stamp key: the baseline is host-singular, so its stamp must not
      # vary with the manifest dir's path (which moves on every brew upgrade).
      STATE_KEY = "host-baseline"

      STALE_MESSAGE = "host baseline stale — run `dev up`"

      # @param manifest_dir [Pathname, String] dir holding dependencies.rb +
      #   deps.lock (the shipped bundle by default)
      # @param state_dir [Pathname, String] host state root — XDG data home
      #   like the learnings cache, NOT ~/.dev/state: project stamps are
      #   per-checkout working state; this is host-layer state
      # @param installer_factory [#call] (lockfile, integrations) → installer;
      #   the DependencyInstaller seam, injectable so tests never touch the host
      def initialize(
        manifest_dir: SHIPPED_DIR,
        state_dir: default_state_dir,
        installer_factory: ->(lockfile, integrations) { DependencyInstaller.new(lockfile:, integrations:) }
      )
        @manifest_dir = Pathname(manifest_dir)
        @state_dir = Pathname(state_dir)
        @installer_factory = installer_factory
      end

      # The warn-only nag for a stale host, nil when converged. A distribution
      # without a shipped lock has nothing to converge and is never stale.
      #
      # @return [String, nil]
      def message
        staleness.install_message && STALE_MESSAGE
      end

      # Install the shipped lock (filtered to this env and host OS, like any
      # project install) and stamp the host converged. Stamping only happens
      # after a fully-successful install, so a crashed run keeps nagging.
      #
      # @return [void]
      def converge
        lockfile = Lockfile.new(dir: @manifest_dir)
        integrations = Registry.host_integrations(project_root: @manifest_dir, cache: Cache.new)
        @installer_factory.call(lockfile, integrations).install(env: Deps.detect_env, host: Deps.detect_host)
        staleness.stamp_installed!
      end

      # The O(1)-guarded converge `dev up` runs first: one digest comparison
      # on a warm host, a full converge on a stale one.
      #
      # @return [Boolean] whether a converge ran
      def converge_if_stale
        return false if message.nil?

        converge
        true
      end

      # Re-resolve the manifest and rewrite the committed lock — dev-repo
      # maintenance (bin/update-baseline.rb), never run on consuming hosts.
      #
      # @param resolver [Resolver] injectable for tests; defaults to the
      #   registry-wired resolver
      # @return [void]
      def update_lock!(resolver: Resolver.new(repositories: Registry.repositories(project_root: @manifest_dir)))
        manifest = @manifest_dir / "dependencies.rb"
        Deps.reset!
        Kernel.load(manifest.to_s)
        declarations = Deps.last_config&.declarations || []
        Lockfile.new(dir: @manifest_dir).lock(
          resolver.resolve(declarations),
          manifest_digest: Digest::SHA256.file(manifest.to_s).hexdigest,
        )
      end

      private

      # The baseline's staleness view: the shipped dir plays the project-root
      # role (it holds the lock), while the stamp lives under the fixed
      # host-singular key.
      #
      # @return [Staleness]
      def staleness
        Staleness.new(project_root: @manifest_dir, state_dir: @state_dir, state_key: STATE_KEY)
      end

      # @return [String] $XDG_DATA_HOME/dev (the learnings-cache precedent)
      def default_state_dir
        data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
        File.join(data_home, "dev")
      end
    end
  end
end
