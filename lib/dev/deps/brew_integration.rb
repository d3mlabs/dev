# typed: strict
# frozen_string_literal: true

require "etc"
require "open3"
require "pathname"
require "uri"
require_relative "brew_repository"
require_relative "integration"
require_relative "dependency"
require_relative "tap"
require_relative "tap_pinner"

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

      # The keg brew has for a formula is not the version the lock pins:
      # either brew's formula moved on since `dev deps update` (the lock is
      # stale) or this machine's keg is behind the lock.
      class VersionMismatchError < StandardError
        extend T::Sig

        # @param formula [String] the install spec (e.g. "llvm@18")
        # @param installed [Array<String>] the keg versions brew reports
        # @param locked [String] the version the lock pins
        sig { params(formula: String, installed: T::Array[String], locked: String).void }
        def initialize(formula:, installed:, locked:)
          super(
            "brew has #{formula} #{installed.join(", ")} but the lock pins #{locked} — " \
            "if brew's formula moved on, run `dev deps update` to re-lock; " \
            "if this machine is behind, `brew upgrade #{formula}`",
          )
        end
      end

      # Pinned-taps mode asked for a formula the lock carries no tap commit
      # for: the lock predates the fact and must be rewritten.
      class UnpinnedFormulaError < StandardError
        extend T::Sig

        # @param name [String] formula name
        sig { params(name: String).void }
        def initialize(name:)
          super("#{name} has no tap_commit in the lock — run `dev deps update` to re-lock before a pinned install")
        end
      end

      # Two formulae of one tap lock it at different commits: a tap is one
      # checkout, and the lock is rewritten whole, so this is a hand-edited
      # or merged lock.
      class TapPinConflictError < StandardError
        extend T::Sig

        # @param tap [String] tap slug
        # @param commits [Array<String>] the commits the lock names for it
        sig { params(tap: String, commits: T::Array[String]).void }
        def initialize(tap:, commits:)
          super("the lock pins #{tap} at #{commits.join(" and ")} — run `dev deps update` to re-lock at one commit")
        end
      end

      # brew itself cannot be asked where its taps live.
      class BrewUnavailableError < StandardError
        extend T::Sig

        # @param stderr [String] what `brew --repository` said
        sig { params(stderr: String).void }
        def initialize(stderr:)
          super("brew --repository failed (#{stderr.strip}) — pinned taps need brew on PATH")
        end
      end

      # argv inserted before `brew` in pinned-taps mode: formulae come from
      # the checked-out taps, never the API, and brew does not move them.
      PINNED_ENV = T.let(["env", "HOMEBREW_NO_INSTALL_FROM_API=1", "HOMEBREW_NO_AUTO_UPDATE=1"].freeze, T::Array[String])

      # @param repository [Repository, nil] source adapter
      # @param store [ArtifactStore, nil] artifact store (unused; brew caches)
      # @param taps [Array<Tap>] Homebrew taps to register before installing
      # @param project_dir [String, Pathname, nil] project root for resolving file:// tap URLs
      # @param brew_prefix [String, Pathname, nil] the Homebrew prefix
      #   (discovered via `brew --prefix` when nil; injectable for tests)
      # @param pin_taps [Boolean] check each formula's tap out at the commit
      #   the lock names and install from the taps instead of brew's API —
      #   the image build's reproducible mode
      # @param tap_pinner [TapPinner, nil] how taps are pinned (built from
      #   `brew --repository` and the declared taps' URLs when nil)
      sig do
        params(
          repository: T.nilable(Repository),
          store: T.nilable(ArtifactStore),
          taps: T::Array[Tap],
          project_dir: T.nilable(T.any(String, Pathname)),
          brew_prefix: T.nilable(T.any(String, Pathname)),
          pin_taps: T::Boolean,
          tap_pinner: T.nilable(TapPinner),
        ).void
      end
      def initialize(repository:, store:, taps: [], project_dir: nil, brew_prefix: nil, pin_taps: false, tap_pinner: nil)
        super(repository:, store:)
        @taps = taps
        @project_dir = T.let(project_dir ? Pathname(project_dir) : nil, T.nilable(Pathname))
        @taps_registered = T.let(false, T::Boolean)
        @brew_prefix = T.let(brew_prefix&.to_s, T.nilable(String))
        @brew_prefix_resolved = T.let(!brew_prefix.nil?, T::Boolean)
        @pin_taps = pin_taps
        @tap_pinner = tap_pinner
      end

      # @return [Boolean] whether installs pin taps at the lock's commits
      sig { returns(T::Boolean) }
      def pin_taps? = @pin_taps

      # Install all brew dependencies. Registers taps on first call, and in
      # pinned-taps mode checks every formula's tap out at its locked commit.
      #
      # Tap registration and pinning stay outside the per-dep isolation:
      # every install is predetermined to fail for the same root cause, so
      # it surfaces as one integration-level failure instead of N per-dep
      # echoes.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      # @raise [TapRegistrationError] if a tap cannot be registered
      # @raise [UnpinnedFormulaError, TapPinConflictError, TapPinner::PinError]
      #   in pinned-taps mode, when the lock cannot pin a tap or git fails to
      # @raise [PartialInstallError] if any dep fails; the rest were attempted
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        ensure_taps_registered
        pin_taps!(dependencies.reject { |dep| dep.metadata["cask"] }) if @pin_taps
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
      # After the install step the keg is verified against the lock: brew
      # installs whatever its registry currently has, so the lock only means
      # something if the result is checked (the B half of reproducible brew).
      #
      # @param dep [Dependency]
      # @raise [InstallError] if brew install fails
      # @raise [VersionMismatchError] if the keg is not the locked version
      sig { params(dep: Dependency).void }
      def install_formula(dep)
        suffix = dep.metadata["version_suffix"]
        formula = suffix ? "#{dep.name}@#{suffix}" : dep.name
        unless brew_installed?(formula)
          spec = dep.metadata["tap"] ? "#{dep.metadata["tap"]}/#{formula}" : formula
          run_brew_install(dep.name, spec)
        end

        locked = dep.version
        verify_installed!(formula, locked) if locked
      end

      # Fail unless one of the formula's kegs is the locked version. Brew's
      # own revision suffix (`_1`) is not part of the upstream version and
      # is ignored.
      #
      # @param formula [String] the install spec (e.g. "llvm@18")
      # @param locked [String] the version the lock pins
      # @return [void]
      # @raise [VersionMismatchError]
      sig { params(formula: String, locked: String).void }
      def verify_installed!(formula, locked)
        installed = installed_versions(formula)
        return if installed.include?(locked)

        raise VersionMismatchError.new(formula:, installed:, locked:)
      end

      # The keg versions brew has for a formula, revision suffixes stripped.
      #
      # @param formula [String]
      # @return [Array<String>] empty when brew reports none
      sig { params(formula: String).returns(T::Array[String]) }
      def installed_versions(formula)
        out, _err, status = T.unsafe(Open3).capture3("brew", "list", "--versions", formula)
        return [] unless status.success?

        out.split.drop(1).map { |version| version.sub(/_\d+\z/, "") }
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
        env = @pin_taps ? PINNED_ENV : []
        _out, err, status = T.unsafe(Open3).capture3(*escalation, *env, "brew", "install", *spec.split)
        return if status.success?

        if sudo_refused?(err)
          raise InstallError,
            "brew install #{spec} needs the prefix owner and sudo -n was refused — " \
            "the brew sudoers edge is missing on this host; run `dev runner register` to re-converge it"
        end

        raise InstallError, "brew install #{spec} failed: #{err}"
      end

      # Check each formula's tap out at the one commit the lock names for it.
      #
      # @param formulae [Array<Dependency>] the formula deps (casks excluded)
      # @return [void]
      # @raise [UnpinnedFormulaError] if a formula locked no tap commit
      # @raise [TapPinConflictError] if a tap is locked at two commits
      # @raise [TapPinner::PinError] if git fails
      sig { params(formulae: T::Array[Dependency]).void }
      def pin_taps!(formulae)
        pins = formulae.map do |dep|
          commit = dep.metadata["tap_commit"]
          raise UnpinnedFormulaError.new(name: dep.name) unless commit

          [T.let(dep.metadata["tap"] || BrewRepository::CORE_TAP, String), T.let(commit, String)]
        end
        pins.group_by(&:first).each do |tap, pairs|
          commits = pairs.map(&:last).uniq
          raise TapPinConflictError.new(tap:, commits:) if commits.length > 1

          tap_pinner.pin!(tap, T.must(commits.first))
        end
      end

      # The pinner: injected, else brew's taps directory with the declared
      # taps' URLs (a declared tap may live anywhere; undeclared ones are
      # GitHub taps by brew's convention).
      #
      # @return [TapPinner]
      # @raise [BrewUnavailableError] if `brew --repository` fails
      sig { returns(TapPinner) }
      def tap_pinner
        @tap_pinner ||= begin
          out, err, status = Open3.capture3("brew", "--repository")
          raise BrewUnavailableError.new(stderr: err) unless status.success?

          urls = @taps.filter_map { |tap| [tap.name, tap.url.to_s] if tap.url }.to_h
          TapPinner.new(taps_root: Pathname(out.strip) / "Library" / "Taps", remote_urls: urls)
        end
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
