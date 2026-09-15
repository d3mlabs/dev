# typed: strict
# frozen_string_literal: true

require "etc"
require "open3"
require "pathname"
require "uri"
require_relative "integration"
require_relative "dependency"
require_relative "tap"

module Dev
  module Deps
    # Lifecycle handler for Homebrew dependencies.
    #
    # install_all installs each formula/cask via brew. Registers taps
    # (if configured) before the first install.
    #
    # Homebrew assumes exactly one non-root owner of exactly one prefix, so
    # on cooperative shared machines (plans#26) a sandboxed agent user
    # cannot write /opt/homebrew. Brew *writes* (tap, install) therefore
    # escalate to the prefix owner via `sudo -n` when the prefix is not
    # writable by the current user — the owner is stat'd at runtime, never
    # hardcoded, and the NOPASSWD edge is converged by the agent host
    # bootstrap (Dev::AgentBootstrap). On a single-user machine the prefix
    # is writable and nothing changes.
    #
    # Env filtering (install vs skip based on ci/dev) is the caller's
    # responsibility — only pass deps that should be installed.
    class BrewIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end
      class TapRegistrationError < StandardError; end

      # @param repository [Repository, nil] source adapter
      # @param cache [Cache, nil] shared download cache
      # @param taps [Array<Tap>] Homebrew taps to register before installing
      # @param project_dir [String, Pathname, nil] project root for resolving file:// tap URLs
      # @param brew_prefix [String, Pathname, nil] the Homebrew prefix
      #   (discovered via `brew --prefix` when nil; injectable for tests)
      sig do
        params(
          repository: T.nilable(Repository),
          cache: T.nilable(Cache),
          taps: T::Array[Tap],
          project_dir: T.nilable(T.any(String, Pathname)),
          brew_prefix: T.nilable(T.any(String, Pathname)),
        ).void
      end
      def initialize(repository:, cache:, taps: [], project_dir: nil, brew_prefix: nil)
        super(repository:, cache:)
        @taps = taps
        @project_dir = T.let(project_dir ? Pathname(project_dir) : nil, T.nilable(Pathname))
        @taps_registered = T.let(false, T::Boolean)
        @brew_prefix = T.let(brew_prefix&.to_s, T.nilable(String))
        @brew_prefix_resolved = T.let(!brew_prefix.nil?, T::Boolean)
      end

      # Install all brew dependencies. Registers taps on first call.
      #
      # Tap registration stays outside the per-dep isolation: every install
      # is predetermined to fail for the same root cause, so it surfaces as
      # one integration-level failure instead of N per-dep echoes.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      # @raise [TapRegistrationError] if a tap cannot be registered
      # @raise [PartialInstallError] if any dep fails; the rest were attempted
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        ensure_taps_registered
        failures = collect_failures(dependencies) do |dep|
          if dep.metadata["cask"]
            install_cask(dep)
          else
            install_formula(dep)
          end
        end
        raise PartialInstallError, failures if failures.any?
      end

      private

      # Register all configured taps (idempotent — runs once).
      sig { void }
      def ensure_taps_registered
        return if @taps_registered

        @taps.each { |tap| register_tap(tap) }
        setup_tap_env
        @taps_registered = true
      end

      # Register a single Homebrew tap (escalated to the prefix owner when
      # the prefix is not ours — see the class doc).
      #
      # @param tap [Tap] tap to register
      # @raise [TapRegistrationError] if `brew tap` fails
      sig { params(tap: Tap).void }
      def register_tap(tap)
        project_dir = @project_dir
        url = tap.url
        if tap.local? && project_dir && url
          path = resolve_file_url(url, project_dir)
          success = system(*T.unsafe(escalation), "brew", "tap", tap.name, path)
          raise TapRegistrationError, "brew tap #{tap.name} #{path} failed#{escalation_hint}" unless success
        elsif url
          url_str = url.to_s
          success = system(*T.unsafe(escalation), "brew", "tap", tap.name, url_str)
          raise TapRegistrationError, "brew tap #{tap.name} #{url_str} failed#{escalation_hint}" unless success
        else
          success = system(*T.unsafe(escalation), "brew", "tap", tap.name)
          raise TapRegistrationError, "brew tap #{tap.name} failed#{escalation_hint}" unless success
        end
      end

      # Set TAP_NAME and LOCAL_TAP_DIR env vars for the first local tap.
      sig { void }
      def setup_tap_env
        project_dir = @project_dir
        return unless project_dir

        local_tap = @taps.find(&:local?)
        return unless local_tap

        ENV["TAP_NAME"] = local_tap.name
        url = local_tap.url
        ENV["LOCAL_TAP_DIR"] = resolve_file_url(url, project_dir) if url
      end

      # Resolve a file:// URI to an absolute path relative to project_dir.
      #
      # @param uri [URI::Generic] file:// URI
      # @param project_dir [Pathname] project root ./ paths resolve against
      # @return [String] absolute path
      sig { params(uri: URI::Generic, project_dir: Pathname).returns(String) }
      def resolve_file_url(uri, project_dir)
        path = uri.path.to_s
        # T.must: start_with?("./") guarantees at least two leading chars.
        path = (project_dir / T.must(path[2..])).to_s if path.start_with?("./")
        File.expand_path(path)
      end

      # Install a Homebrew formula.
      #
      # The install target is the versioned formula (e.g. "llvm@18"), built from
      # the declared version *suffix* in metadata — never the resolved stable
      # version (dep.version), which is a record like "18.1.8" and is not a valid
      # formula name (there is no "llvm@18.1.8").
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install fails
      sig { params(dep: Dependency).void }
      def install_formula(dep)
        suffix = dep.metadata["version_suffix"]
        formula = suffix ? "#{dep.name}@#{suffix}" : dep.name
        return if brew_installed?(formula)

        spec = dep.metadata["tap"] ? "#{dep.metadata["tap"]}/#{formula}" : formula
        run_brew_install(dep.name, spec)
      end

      # Install a Homebrew cask.
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install --cask fails
      sig { params(dep: Dependency).void }
      def install_cask(dep)
        return if brew_installed?(dep.name)
        run_brew_install(dep.name, "--cask #{dep.name}")
      end

      # Check if a formula/cask is already installed.
      #
      # @param name [String] formula or cask name
      # @return [Boolean, nil] nil when the brew command itself cannot run
      sig { params(name: String).returns(T.nilable(T::Boolean)) }
      def brew_installed?(name)
        system("brew list #{name} >/dev/null 2>&1")
      end

      # Run `brew install` with the given spec (escalated to the prefix
      # owner when the prefix is not ours — see the class doc).
      #
      # @param name [String] dependency name (for error messages)
      # @param spec [String] full install spec (e.g. "cmake@3.31.4")
      # @raise [InstallError] if brew exits non-zero
      sig { params(name: String, spec: String).void }
      def run_brew_install(name, spec)
        _out, err, status = T.unsafe(Open3).capture3(*escalation, "brew", "install", *spec.split)
        return if status.success?

        if sudo_refused?(err)
          raise InstallError,
            "brew install #{spec} needs the prefix owner and sudo -n was refused — " \
            "the brew sudoers edge is missing on this host; run `dev runner register` to re-converge it"
        end

        raise InstallError, "brew install #{spec} failed: #{err}"
      end

      # argv prefix for brew write commands: empty when the prefix is
      # writable by the current user, `sudo -n` to the stat'd prefix owner
      # otherwise. -n so a missing sudoers edge fails fast instead of
      # hanging on a password prompt no one is watching.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def escalation
        prefix = brew_prefix
        return [] if prefix.nil? || File.writable?(prefix)

        ["sudo", "-n", "-u", T.must(Etc.getpwuid(File.stat(prefix).uid)).name]
      end

      # Remediation appended to escalated-write failures: the two host facts
      # that break them (missing sudoers edge, a path the owner cannot read).
      #
      # @return [String] "" when not escalated
      sig { returns(String) }
      def escalation_hint
        return "" if escalation.empty?

        " (escalated to the brew prefix owner: ensure any local tap path is readable " \
          "by them and the sudoers brew edge exists — run `dev runner register` to re-converge it)"
      end

      # The Homebrew prefix, resolved once: injected (tests), else asked of
      # brew itself. nil when brew is absent — writes then run unescalated
      # and surface brew's own error.
      #
      # @return [String, nil]
      sig { returns(T.nilable(String)) }
      def brew_prefix
        return @brew_prefix if @brew_prefix_resolved

        @brew_prefix_resolved = true
        out, _err, status = Open3.capture3("brew", "--prefix")
        @brew_prefix = (out.strip if status.success? && !out.strip.empty?)
      rescue Errno::ENOENT
        @brew_prefix = nil
      end

      # @param err [String] a brew invocation's stderr
      # @return [Boolean] whether sudo -n refused for lack of a NOPASSWD rule
      sig { params(err: String).returns(T::Boolean) }
      def sudo_refused?(err)
        err.include?("a password is required")
      end
    end
  end
end
