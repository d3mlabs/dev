# typed: strict
# frozen_string_literal: true

require "digest"
require "etc"
require "open3"
require "pathname"
require "tmpdir"
require "uri"
require "dev/brew_env"
require "dev/shadowenv_path"
require "dev/shadowenv_python"
require "dev/shadowenv_ruby"
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
    # Brew links one keg per formula onto PATH and deletes the rest on
    # `brew upgrade`/`brew cleanup`; a lock names one exact version. So after
    # installing, the integration activates each locked keg's `bin` in the
    # project shadowenv — the project runs the version it locked whichever
    # keg brew linked, and two projects locking two versions coexist — and
    # records the formulae in brew's no-cleanup list so the kegs outlive the
    # user's own brew hygiene (ADR-0010, dev#289). Both are per-project side
    # effects and only happen when the integration knows its project.
    #
    # A lock is enforced by verifying the keg, and satisfied by converging
    # it: a formula brew has at other versions than the lock pins (a
    # checkpoint behind a re-lock, a branch locking an older version) is
    # brought to the locked version before the verification fails. The
    # lock carries every bottle the version publishes (ADR-0004), so the
    # exact bottle for this machine is poured from its link — no index
    # involved, up or down; a formula with no bottle to pour here is
    # upgraded by brew from a refreshed index instead (dev#350).
    #
    # Env filtering (install vs skip based on ci/dev) is the caller's
    # responsibility — only pass deps that should be installed.
    class BrewIntegration < Integration
      extend T::Sig

      class InstallError < StandardError; end
      class TapRegistrationError < StandardError; end

      # The bottle the lock names could not be downloaded from its link.
      class BottleDownloadError < StandardError
        extend T::Sig

        # @param link [String] the bottle URL the lock carries
        # @param stderr [String] what curl said
        sig { params(link: String, stderr: String).void }
        def initialize(link:, stderr:)
          super("bottle download failed for #{link}: #{stderr.strip}")
        end
      end

      # The downloaded bottle is not the bytes the lock names.
      class BottleIntegrityError < StandardError
        extend T::Sig

        # @param formula [String] the formula (e.g. "cmake")
        # @param locked [String] the version the lock pins
        # @param tag [String] the bottle tag poured for this machine
        # @param expected [String] the lock's SHA256 hex digest
        # @param actual [String] the download's SHA256 hex digest
        sig { params(formula: String, locked: String, tag: String, expected: String, actual: String).void }
        def initialize(formula:, locked:, tag:, expected:, actual:)
          super("SHA256 mismatch for the #{formula} #{locked} (#{tag}) bottle: the lock names #{expected}, got #{actual}")
        end
      end

      # An interpreter pin installed and verified, yet its keg is not in the
      # Cellar to activate: nothing would run under the locked interpreter,
      # which is worse than failing here.
      class KegNotFoundError < StandardError
        extend T::Sig

        # @param formula [String] the formula (e.g. "ruby@4.0.9")
        # @param locked [String] the version the lock pins
        # @param cellar [Pathname, nil] where the keg was looked for
        sig { params(formula: String, locked: String, cellar: T.nilable(Pathname)).void }
        def initialize(formula:, locked:, cellar:)
          super("#{formula} #{locked} has no keg under #{cellar || "(no brew prefix)"} to activate")
        end
      end

      # No keg of a formula is the version the lock pins, and converging
      # did not produce one: brew's formula moved on since `dev deps update`
      # and the version publishes no bottle this machine can pour, so the
      # lock is stale.
      class VersionMismatchError < StandardError
        extend T::Sig

        # @param formula [String] the install spec (e.g. "llvm@18")
        # @param installed [Array<String>] the keg versions brew reports
        # @param locked [String] the version the lock pins
        sig { params(formula: String, installed: T::Array[String], locked: String).void }
        def initialize(formula:, installed:, locked:)
          has = installed.empty? ? "no keg of #{formula}" : "#{formula} #{installed.join(", ")}"
          super(
            "brew has #{has} but the lock pins #{locked} and dev could not converge the keg — " \
            "if brew's formula moved on, run `dev deps update` to re-lock",
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
      # checkout, so a pinned install cannot serve both. A conservative
      # re-lock keeps each pin's own commit (dev#355), so the taps of a lock
      # whose pins moved at different times legitimately carry several —
      # `--all` re-resolves every pin at one HEAD.
      class TapPinConflictError < StandardError
        extend T::Sig

        # @param tap [String] tap slug
        # @param commits [Array<String>] the commits the lock names for it
        sig { params(tap: String, commits: T::Array[String]).void }
        def initialize(tap:, commits:)
          super("the lock pins #{tap} at #{commits.join(" and ")} — run `dev deps update --all` to re-lock at one commit")
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

      # Environment added in pinned-taps mode: formulae come from the
      # checked-out taps, never the API, and brew does not move them.
      PINNED_ENV = T.let(["HOMEBREW_NO_INSTALL_FROM_API=1", "HOMEBREW_NO_AUTO_UPDATE=1"].freeze, T::Array[String])
      TOOL = "brew"
      # brew's bottle file name: `<formula>--<version>.<tag>.bottle[.<rebuild>].tar.gz`.
      # `brew --cache` answers it for the bottle brew would pour (the tag is
      # this machine's), and `brew install <path>` pours a local file only
      # when its name has this shape.
      BOTTLE_FILENAME = /\.([a-z0-9_]+)\.bottle\.(?:\d+\.)?tar\.gz\z/
      # GitHub Packages serves homebrew/core's bottles behind an anonymous
      # bearer token — brew's own download strategy sends this same one.
      GITHUB_PACKAGES_HOST = "ghcr.io"
      GITHUB_PACKAGES_AUTH = "Authorization: Bearer QQ=="
      # After the project Ruby (510) so brew tools never shadow its bin;
      # before llvm and xcode (520), which keep the last word on what they set.
      LISP_FILENAME = "515_brew.lisp"

      # The interpreters that are brew pins (Registry's :ruby and :python
      # rows) and the language-specific activation each gets once its keg is
      # installed and on the project PATH: gem env for Ruby, the project
      # venv for Python. Keyed on the pin's integration symbol, so the step
      # follows the lock, not a formula name. (A port on the Registry entry
      # once #300 gives Entry its materialization — the table lives here
      # until then.)
      INTERPRETERS = T.let(
        { ruby: Dev::ShadowenvRuby, python: Dev::ShadowenvPython }.freeze,
        T::Hash[Symbol, T::Module[T.anything]],
      )

      class << self
        extend T::Sig

        # brew is the host prerequisite: the tools every other integration
        # shells to (xcodes, wwise-cli, the project Ruby) are formulae, so
        # the brew batch installs before every other integration's.
        #
        # @return [Boolean] always true
        sig { override.returns(T::Boolean) }
        def host_prerequisite?
          true
        end
      end

      # @param repository [Repository, nil] source adapter
      # @param store [ArtifactStore, nil] the store whose brew tool cache brew downloads into
      # @param taps [Array<Tap>] Homebrew taps to register before installing
      # @param project_dir [String, Pathname, nil] project root for resolving file:// tap URLs
      # @param brew_prefix [String, Pathname, nil] the Homebrew prefix
      #   (discovered via `brew --prefix` when nil; injectable for tests)
      # @param pin_taps [Boolean] check each formula's tap out at the commit
      #   the lock names and install from the taps instead of brew's API —
      #   the image build's reproducible mode
      # @param tap_pinner [TapPinner, nil] how taps are pinned (built from
      #   `brew --repository` and the declared taps' URLs when nil)
      # @param brew_env [BrewEnv, nil] the user's brew.env, where locked
      #   formulae are recorded as never-clean-up; nil records nothing (a
      #   caller with no user to speak for — tests, an image bootstrap)
      # @param interpreters [Hash{Symbol => Module}] the language activation
      #   for each interpreter pin type, by integration symbol: each answers
      #   `activate!(keg:, version:, project_root:)` and is called after the
      #   PATH activation with the locked keg (INTERPRETERS by default)
      sig do
        params(
          repository: T.nilable(Repository),
          store: T.nilable(ArtifactStore),
          taps: T::Array[Tap],
          project_dir: T.nilable(T.any(String, Pathname)),
          brew_prefix: T.nilable(T.any(String, Pathname)),
          pin_taps: T::Boolean,
          tap_pinner: T.nilable(TapPinner),
          brew_env: T.nilable(BrewEnv),
          interpreters: T::Hash[Symbol, T::Module[T.anything]],
        ).void
      end
      def initialize(repository:, store:, taps: [], project_dir: nil, brew_prefix: nil, pin_taps: false, tap_pinner: nil,
        brew_env: nil, interpreters: INTERPRETERS)
        super(repository:, store:)
        @taps = taps
        @project_dir = T.let(project_dir ? Pathname(project_dir) : nil, T.nilable(Pathname))
        @taps_registered = T.let(false, T::Boolean)
        @brew_prefix = T.let(brew_prefix&.to_s, T.nilable(String))
        @brew_prefix_resolved = T.let(!brew_prefix.nil?, T::Boolean)
        @pin_taps = pin_taps
        @tap_pinner = tap_pinner
        @brew_env = brew_env
        @interpreters = interpreters
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
      # What installed is activated and retained even when something else
      # failed: a half-installed project still runs what it has, and the
      # aggregate error says what it does not.
      #
      # @param dependencies [Array<Dependency>] brew deps to install
      # @raise [TapRegistrationError] if a tap cannot be registered
      # @raise [UnpinnedFormulaError, TapPinConflictError, TapPinner::PinError]
      #   in pinned-taps mode, when the lock cannot pin a tap or git fails to
      # @raise [BrewEnv::WriteError] if the no-cleanup list cannot be written
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
        failed = failures.map(&:first)
        installed_formulae = dependencies.reject { |dep| dep.metadata["cask"] || failed.include?(dep.name) }
        activate!(installed_formulae)
        activate_interpreters!(installed_formulae)
        retain!(installed_formulae)
        raise PartialInstallError, failures if failures.any?
      end

      private

      # Run each installed interpreter pin's language activation against its
      # keg — after the PATH activation, so the keg's bin is already on the
      # project PATH when the gem env or venv is built on it.
      #
      # @param formulae [Array<Dependency>] the formulae that installed
      # @return [void]
      # @raise [KegNotFoundError] if an interpreter's keg is not in the Cellar
      sig { params(formulae: T::Array[Dependency]).void }
      def activate_interpreters!(formulae)
        project_dir = @project_dir
        return unless project_dir

        formulae.each do |dep|
          activation = @interpreters[dep.integration]
          locked = dep.version
          next unless activation && locked

          keg = keg_dir(dep)
          raise KegNotFoundError.new(formula: formula_name(dep), locked:, cellar: cellar_dir(dep)) unless keg

          # T.unsafe: the activation is a module answering activate! by
          # contract (INTERPRETERS); its own sig validates at runtime.
          T.unsafe(activation).activate!(keg:, version: locked, project_root: project_dir)
        end
      end

      # Put each locked keg's `bin` on the project PATH through shadowenv.
      # A formula that locked no version (a tap formula brew reports none
      # for) or whose keg has no `bin` contributes nothing; the provide
      # record still names every formula so the file reads as the lock does.
      #
      # @param formulae [Array<Dependency>] the formulae that installed
      # @return [void]
      sig { params(formulae: T::Array[Dependency]).void }
      def activate!(formulae)
        project_dir = @project_dir
        return unless project_dir

        activated = formulae.map { |dep| [formula_name(dep), dep.version].compact.join("@") }.sort.join(" ")
        bins = formulae.filter_map { |dep| keg_bin(dep) }
        written = ShadowenvPath.setup!(project_root: project_dir, filename: LISP_FILENAME, provide: ["brew", activated], paths: bins)
        puts ">>> brew: activated #{bins.size} keg bin(s) on the project PATH (.shadowenv.d/#{LISP_FILENAME})" if written
      end

      # The `bin` of the keg whose version is the locked one, if both exist.
      # Kegs are named by brew's full version, revision suffix included
      # (`18.1.8_1`), which is why the Cellar is listed rather than the
      # path built from the lock.
      #
      # @param dep [Dependency]
      # @return [String, nil]
      sig { params(dep: Dependency).returns(T.nilable(String)) }
      def keg_bin(dep)
        bin = keg_dir(dep)&.join("bin")
        bin&.directory? ? bin.to_s : nil
      end

      # The keg whose version is the locked one, if the Cellar has it.
      #
      # @param dep [Dependency]
      # @return [Pathname, nil]
      sig { params(dep: Dependency).returns(T.nilable(Pathname)) }
      def keg_dir(dep)
        locked = dep.version
        cellar = cellar_dir(dep)
        return nil if locked.nil? || cellar.nil? || !cellar.directory?

        cellar.children.find { |child| child.directory? && child.basename.to_s.sub(/_\d+\z/, "") == locked }
      end

      # The formula's Cellar directory, if brew's prefix is known.
      #
      # @param dep [Dependency]
      # @return [Pathname, nil]
      sig { params(dep: Dependency).returns(T.nilable(Pathname)) }
      def cellar_dir(dep)
        prefix = brew_prefix
        return nil if prefix.nil?

        Pathname(prefix) / "Cellar" / formula_name(dep)
      end

      # Tell brew never to clean up the locked formulae. Skipped when brew
      # writes are escalated to another prefix owner: brew.env is per user,
      # and the user whose `brew cleanup` matters is the owner, not us.
      #
      # @param formulae [Array<Dependency>] the formulae that installed
      # @return [void]
      # @raise [BrewEnv::WriteError]
      sig { params(formulae: T::Array[Dependency]).void }
      def retain!(formulae)
        brew_env = @brew_env
        return unless brew_env && @project_dir
        return if formulae.empty?

        unless escalation.empty?
          $stderr.puts "dev: brew writes are escalated to the prefix owner; not recording locked formulae in this user's brew.env"
          return
        end

        brew_env.retain!(formulae.map { |dep| formula_name(dep) })
      end

      # The formula brew knows the dep as: `name@suffix` for a versioned
      # declaration, the bare name otherwise.
      #
      # @param dep [Dependency]
      # @return [String]
      sig { params(dep: Dependency).returns(String) }
      def formula_name(dep)
        suffix = dep.metadata["version_suffix"]
        suffix ? "#{dep.name}@#{suffix}" : dep.name
      end

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
      # something if the result is checked (the B half of reproducible brew)
      # — and a keg at another version is converged before the check fails.
      #
      # @param dep [Dependency]
      # @raise [InstallError] if a brew write fails
      # @raise [BottleDownloadError, BottleIntegrityError] if the locked
      #   bottle cannot be fetched as the lock describes it
      # @raise [VersionMismatchError] if no keg is the locked version
      sig { params(dep: Dependency).void }
      def install_formula(dep)
        formula = formula_name(dep)
        run_brew_install(dep.name, install_spec(dep)) unless brew_installed?(formula)

        locked = dep.version
        verify_installed!(dep, formula, locked) if locked
      end

      # Fail unless one of the formula's kegs is the locked version, after
      # converging the Cellar when none is. Brew's own revision suffix
      # (`_1`) is not part of the upstream version and is ignored.
      #
      # Pinned-taps mode never converges: the formula comes from its tap at
      # the locked commit, which is the whole install path there, and a
      # `brew update` would move the checkout the pin just made.
      #
      # @param dep [Dependency]
      # @param formula [String] the formula (e.g. "llvm@18")
      # @param locked [String] the version the lock pins
      # @return [void]
      # @raise [VersionMismatchError]
      sig { params(dep: Dependency, formula: String, locked: String).void }
      def verify_installed!(dep, formula, locked)
        installed = installed_versions(formula)
        return if installed.include?(locked)

        unless @pin_taps
          converge!(dep, formula, locked, installed)
          installed = installed_versions(formula)
          return if installed.include?(locked)
        end

        raise VersionMismatchError.new(formula:, installed:, locked:)
      end

      # Bring the formula to the locked version: pour the bottle the lock
      # names for this machine when it names one, else have brew upgrade
      # the formula from a refreshed index.
      #
      # @param dep [Dependency]
      # @param formula [String]
      # @param locked [String]
      # @param installed [Array<String>] the keg versions brew has
      # @return [void]
      # @raise [InstallError, BottleDownloadError, BottleIntegrityError]
      sig { params(dep: Dependency, formula: String, locked: String, installed: T::Array[String]).void }
      def converge!(dep, formula, locked, installed)
        has = installed.empty? ? "absent" : installed.join(", ")
        puts ">>> brew: #{formula} is #{has} here — converging to the locked #{locked}"
        spec = install_spec(dep)
        tag, bottle = locked_bottle(dep, spec)
        if tag && bottle
          pour!(formula, locked, tag, bottle)
        else
          upgrade!(spec)
        end
      end

      # The lock's bottle for this machine: the entry of the pin's
      # `platforms` block under the tag brew would pour, when the pin
      # records bottles (ADR-0004) and the version publishes one for it.
      #
      # @param dep [Dependency]
      # @param spec [String] the install spec
      # @return [[String, Hash], nil] the tag and its { "hash", "link" }
      sig { params(dep: Dependency, spec: String).returns(T.nilable([String, T::Hash[String, T.untyped]])) }
      def locked_bottle(dep, spec)
        platforms = dep.metadata["platforms"]
        return nil unless platforms

        tag = bottle_tag(spec)
        bottle = tag && platforms[tag]
        return nil unless tag && bottle && bottle["hash"] && bottle["link"]

        [tag, bottle]
      end

      # This machine's bottle tag, read off the file name brew would
      # download the formula's bottle to — brew's own tag matching, older
      # macOS fallbacks and `all` bottles included. nil when brew would
      # build the formula from source (a tarball name carries no tag).
      #
      # @param spec [String] the install spec
      # @return [String, nil]
      sig { params(spec: String).returns(T.nilable(String)) }
      def bottle_tag(spec)
        out, _err, status = Open3.capture3("brew", "--cache", "--formula", spec)
        return nil unless status.success?

        BOTTLE_FILENAME.match(File.basename(out.strip))&.[](1)
      end

      # Pour the locked bottle. brew links a newer keg over the linked one
      # (an upgrade), but refuses an older keg under it and any other
      # version of a keg-only formula whose opt link is taken; when the
      # plain pour leaves no locked keg, the second one skips those checks
      # and brew's link — the project activates the keg by path, and brew's
      # link stays the user's.
      #
      # @param formula [String]
      # @param locked [String]
      # @param tag [String] the bottle tag poured
      # @param bottle [Hash] the lock's { "hash", "link" } for the tag
      # @return [void]
      # @raise [InstallError] if the forced pour fails
      # @raise [BottleDownloadError, BottleIntegrityError]
      sig { params(formula: String, locked: String, tag: String, bottle: T::Hash[String, T.untyped]).void }
      def pour!(formula, locked, tag, bottle)
        path = fetch_bottle(formula, locked, tag, bottle).to_s
        puts ">>> brew: pouring the #{formula} #{locked} (#{tag}) bottle"
        brew_write(["install", path])
        return if installed_versions(formula).include?(locked)

        brew_write!(["install", "--force", "--skip-link", path])
      end

      # The locked bottle as a local file in the store, fetched from the
      # lock's link and checked against the lock's digest the first time.
      # The store, not brew's download cache: brew prunes its own, and the
      # file keeps brew's bottle name so `brew install` recognizes it.
      #
      # @param formula [String]
      # @param locked [String]
      # @param tag [String]
      # @param bottle [Hash] the lock's { "hash", "link" }
      # @return [Pathname]
      # @raise [BottleDownloadError, BottleIntegrityError]
      sig { params(formula: String, locked: String, tag: String, bottle: T::Hash[String, T.untyped]).returns(Pathname) }
      def fetch_bottle(formula, locked, tag, bottle)
        expected = bottle["hash"].to_s.delete_prefix("SHA256=")
        key = "#{TOOL}/#{expected}/#{formula}--#{locked}.#{tag}.bottle.tar.gz"
        cached = store!.blob(key)
        return cached if cached

        puts ">>> brew: downloading the #{formula} #{locked} (#{tag}) bottle"
        Dir.mktmpdir("dev-brew-bottle-") do |tmpdir|
          file = File.join(tmpdir, File.basename(key))
          download_bottle(bottle["link"].to_s, file)
          actual = Digest::SHA256.file(file).hexdigest
          raise BottleIntegrityError.new(formula:, locked:, tag:, expected:, actual:) unless actual == expected

          File.open(file, "rb") { |io| store!.put_blob(key, io) }
        end
        store!.blob_path(key)
      end

      # @param link [String] the bottle URL
      # @param dest [String] where to write it
      # @return [void]
      # @raise [BottleDownloadError] if curl fails
      sig { params(link: String, dest: String).void }
      def download_bottle(link, dest)
        auth = URI(link).host == GITHUB_PACKAGES_HOST ? ["-H", GITHUB_PACKAGES_AUTH] : []
        _out, err, status = T.unsafe(Open3).capture3("curl", "-fsSL", *auth, "-o", dest, link)
        raise BottleDownloadError.new(link:, stderr: err) unless status.success?
      end

      # No bottle to pour: refresh brew's index (a checkpoint's is as old as
      # the checkpoint) and let brew upgrade the formula. This converges a
      # machine behind the lock; a lock behind brew stays mismatched, and
      # the verification says so. An offline `brew update` is a warning —
      # the upgrade and the verification decide.
      #
      # @param spec [String] the install spec
      # @return [void]
      # @raise [InstallError] if brew upgrade fails
      sig { params(spec: String).void }
      def upgrade!(spec)
        err, success = brew_write(["update"])
        $stderr.puts "dev: warning: brew update failed (#{err.strip}) — upgrading from the index brew has" unless success
        brew_write!(["upgrade", spec])
      end

      # The spec brew installs the dep by: the formula, tap-qualified for a
      # tap formula.
      #
      # @param dep [Dependency]
      # @return [String]
      sig { params(dep: Dependency).returns(String) }
      def install_spec(dep)
        tap = dep.metadata["tap"]
        tap ? "#{tap}/#{formula_name(dep)}" : formula_name(dep)
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

      # Run `brew install` with the given spec.
      #
      # @param name [String] dependency name (for error messages)
      # @param spec [String] full install spec (e.g. "cmake@3.31.4")
      # @raise [InstallError] if brew exits non-zero
      sig { params(name: String, spec: String).void }
      def run_brew_install(name, spec)
        brew_write!(["install", *spec.split])
      end

      # Run a brew write and fail when it does.
      #
      # @param args [Array<String>] brew's argv (e.g. ["upgrade", "cmake"])
      # @return [void]
      # @raise [InstallError] if brew exits non-zero
      sig { params(args: T::Array[String]).void }
      def brew_write!(args)
        err, success = brew_write(args)
        return if success

        command = "brew #{args.join(" ")}"
        if sudo_refused?(err)
          raise InstallError,
            "#{command} needs the prefix owner and sudo -n was refused — " \
            "the brew sudoers edge is missing on this host; run `dev runner register` to re-converge it"
        end

        raise InstallError, "#{command} failed: #{err}"
      end

      # Run a brew write — install, upgrade, update — escalated to the
      # prefix owner when the prefix is not ours (see the class doc) and
      # under brew's env, reporting rather than raising.
      #
      # @param args [Array<String>] brew's argv
      # @return [[String, Boolean]] brew's stderr and whether it succeeded
      sig { params(args: T::Array[String]).returns([String, T::Boolean]) }
      def brew_write(args)
        _out, err, status = T.unsafe(Open3).capture3(*escalation, *brew_env, "brew", *args)
        # success? is nil when the process did not exit normally — a failure.
        [err, status.success? || false]
      end

      # argv inserted between the escalation and `brew` on every install:
      # `env` with brew's download cache in the store (so the host, the
      # container and a cold run share one, and `dev cache gc` can reclaim
      # it) plus the pinned-taps variables when pinning. The `env` form, not
      # a Ruby env hash, so the variables survive `sudo -n -u <owner>`.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def brew_env
        ["env", "HOMEBREW_CACHE=#{store!.tool_cache(TOOL)}", *(@pin_taps ? PINNED_ENV : [])]
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
