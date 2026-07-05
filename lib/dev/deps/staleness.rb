# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require_relative "lockfile"

module Dev
  module Deps
    # Detects drift between the three layers of dependency state — the
    # manifest (dependencies.rb), the lockfiles, and what was last installed —
    # with two O(1) digest comparisons at every command start:
    #
    #   1. manifest vs lockfile: dependencies.rb digest against the digest
    #      recorded in the lockfile header by `dev update-deps` →
    #      "declarations changed — run dev update-deps".
    #   2. lockfile vs installed stamp: a digest of the lockfile contents
    #      against the stamp written after the last fully-successful install →
    #      "lock changed since last install — run dev up".
    #
    # The stamp lives per-machine, outside the repo (never committed), at
    # ~/.dev/state/<project-key>/installed-digest. It is content-addressed
    # (no mtimes — git rewrites them) and written only on success, so a
    # crashed install keeps nagging. A missing stamp means never installed —
    # the same nag. Checks warn on workstations and error in CI (frozen
    # semantics — CI environments install fresh, so a mismatch there is a
    # pipeline bug, not a reminder).
    #
    # Stamps catch sequence drift (edit without update-deps, lock bump without
    # dev up), not out-of-band mutation of installed artifacts — that's a
    # deferred doctor-style per-integration sweep.
    class Staleness
      STAMP_FILE = "installed-digest"

      # Lockfiles whose contents constitute "what an install consumed", in
      # fixed order for a deterministic digest. Gemfile.lock is included
      # because dev generates it from the gem declarations — it is a lockfile
      # of this system in everything but name.
      LOCK_FILES = [
        Lockfile::DEPS_LOCK_FILE,
        Lockfile::BUILD_DEPS_LOCK_FILE,
        "Gemfile.lock",
      ].freeze

      # @param project_root [Pathname] repo root (holds dependencies.rb + lockfiles)
      # @param state_dir [Pathname] per-machine state root (default ~/.dev/state)
      def initialize(project_root:, state_dir: Pathname(File.expand_path("~/.dev/state")))
        @project_root = Pathname(project_root)
        @state_dir = Pathname(state_dir)
      end

      # All current staleness messages, oldest layer first (a stale manifest
      # implies a stale install; fixing them in order is the happy path).
      #
      # @return [Array<String>] empty when everything is in sync
      def messages
        [manifest_message, install_message].compact
      end

      # Layer 1: has dependencies.rb changed since the lockfiles were generated?
      #
      # @return [String, nil]
      def manifest_message
        manifest = @project_root / "dependencies.rb"
        return nil unless manifest.exist?

        recorded = Lockfile.new(dir: @project_root).manifest_digest
        # No digest recorded: a legacy lockfile (predates the check) — stay
        # quiet until its next update-deps stamps one. No lockfile at all is
        # layer-2's problem (nothing was ever installed either).
        return nil unless recorded

        current = Digest::SHA256.file(manifest.to_s).hexdigest
        return nil if current == recorded

        "dependencies.rb changed since the lockfiles were generated — run dev update-deps"
      end

      # Layer 2: have the lockfiles changed since the last successful install
      # on this machine?
      #
      # @return [String, nil]
      def install_message
        current = lockfile_digest
        return nil unless current # no lockfiles: nothing declared, nothing to install

        stamped = stamp_path.exist? ? stamp_path.read.strip : nil
        return nil if current == stamped

        if stamped
          "lockfiles changed since the last install — run dev up"
        else
          "dependencies have never been installed on this machine — run dev up"
        end
      end

      # Record the just-installed lockfile state. Called only after a fully
      # successful install, so a crashed run leaves the previous stamp (or
      # none) and the nag persists.
      #
      # @return [void]
      def stamp_installed!
        digest = lockfile_digest
        return unless digest

        FileUtils.mkdir_p(stamp_path.dirname)
        stamp_path.write(digest)
      end

      # SHA-256 over the concatenated lockfile contents (fixed order, missing
      # files marked absent so adding a lockfile changes the digest).
      #
      # @return [String, nil] hex digest, or nil when no lockfile exists
      def lockfile_digest
        paths = LOCK_FILES.map { |name| @project_root / name }
        return nil if paths.none?(&:exist?)

        digest = Digest::SHA256.new
        paths.each do |path|
          digest << (path.exist? ? path.read : "<absent:#{path.basename}>")
        end
        digest.hexdigest
      end

      # @return [Pathname]
      def stamp_path
        @state_dir / project_key / STAMP_FILE
      end

      private

      # Per-checkout state key: readable basename + a short path digest so two
      # checkouts of the same project on one machine get independent stamps.
      #
      # @return [String]
      def project_key
        expanded = File.expand_path(@project_root.to_s)
        "#{File.basename(expanded)}-#{Digest::SHA256.hexdigest(expanded)[0, 8]}"
      end
    end
  end
end
