# typed: strict
# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"
require "dev/provisioning_guard"
require_relative "artifact"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports Homebrew formulae: the discrete universe is the formula-spec
    # family — the bare spec plus its versioned siblings (llvm, llvm@18, …),
    # each contributing the one stable version it currently has.
    #
    # Brew is a moving registry (one current version per spec), but the
    # family is enumerable first-class. For core, `brew info --json=v1 <name>`
    # reports the bare spec's facts plus its versioned_formulae list; for a
    # third-party tap brew reports an empty family, so the tap's own formula
    # list (`brew tap-info --json`) is read instead and the bare spec is
    # optional — a tap publishing one immutable `ruby@4.0.x` per patch is a
    # family with no bare member. Either way one batched info call fetches
    # every member's facts; a requirement is evaluated over those real
    # versions (BrewScheme orders them tolerantly; GemScheme, for :ruby,
    # ranges over the stable versions), and each member's suffix rides its
    # version as the version_suffix fact BrewIntegration installs by.
    # Casks are a separate universe (BrewCaskRepository) under :cask.
    #
    # Each version publishes its bottles: every bottle tag is a platform and
    # every bottle (URL + sha256) that platform's artifact, so the pin
    # records what the formula publishes rather than what the writing
    # machine would download. Two more facts ride each version for the
    # image build (reproducible brew, A): `tap_commit`, the commit the
    # formula's tap is at (brew's `tap_git_head`), and `format` — "bottle"
    # when the formula bottles for the image platform, else "source" (the
    # build compiles it). Brew's local info for a core formula lists only
    # this machine's bottle, so core bottles come from the public formula
    # API.
    #
    # A version's source — what a re-lock keeps the pin by — is the tap at
    # that commit, `tap@commit`: the one reference brew installs a specific
    # formula version from (the pinned-taps install checks the tap out
    # there). `tap_commit` stays in the version's metadata as the install's
    # own fact.
    #
    # Every brew the repository spawns runs under HOMEBREW_NO_AUTO_UPDATE=1.
    # Brew's default is an implicit auto-update first — refreshing its
    # formula API cache under a lock in `$(brew --prefix)/var/homebrew/locks`,
    # which only the prefix owner can write. A resolution asks brew
    # questions, and on a shared prefix (an agent user, a second developer,
    # a runner service user) the question must not fail on a write dev
    # never wanted: hosts converge from the tap at the lock's `tap_commit`,
    # not from brew's live index, so no query refreshes it. The one refresh
    # dev asks for is `refresh_index!`, once, before a bare `dev deps
    # update`: that verb asks for today's version of every formula, and
    # "today" should be the clock's, not the writing machine's last `brew
    # update`.
    class BrewRepository < Repository
      extend T::Sig

      # The env every brew query is spawned with (see the class doc).
      READ_ENV = T.let({ "HOMEBREW_NO_AUTO_UPDATE" => "1" }.freeze, T::Hash[String, String])
      # The Homebrew core tap, whose formulae brew reads from the API.
      CORE_TAP = "homebrew/core"
      # The bottle tag of the build-container image's platform.
      IMAGE_BOTTLE_TAG = "x86_64_linux"
      FORMULA_API = "https://formulae.brew.sh/api/formula"
      FORMAT_BOTTLE = "bottle"
      FORMAT_SOURCE = "source"
      # The metadata key under which a version records the commit its tap
      # was at (brew's `tap_git_head`): the fact a pinned install checks
      # the tap out at.
      TAP_COMMIT = "tap_commit"
      # Separates the tap from the commit in a formula pin's source.
      SOURCE_SEPARATOR = "@"

      class BrewInfoError < StandardError; end

      # `brew update` failed: offline, a remote gone, or a prefix this user
      # cannot write the update lock in.
      class IndexRefreshError < StandardError
        extend T::Sig

        # @param stderr [String] what `brew update` said
        sig { params(stderr: String).void }
        def initialize(stderr:)
          super("brew update failed (#{stderr.strip})")
        end
      end

      class << self
        extend T::Sig

        # A formula pin's source: the tap at the commit where the formula is
        # the pin's version. The same spelling whichever side builds it —
        # the repository stamping a fresh version, or the lockfile lifting
        # a pin written before pins carried a source.
        #
        # @param tap [String, nil] the tap slug; nil is core
        # @param commit [String] the tap's commit
        # @return [String] `tap@commit`
        sig { params(tap: T.nilable(String), commit: String).returns(String) }
        def source_at(tap, commit)
          "#{tap || CORE_TAP}#{SOURCE_SEPARATOR}#{commit}"
        end
      end

      # Refresh brew's index — `brew update` — so the versions the queries
      # that follow report are today's. A write to the prefix, so the test
      # harness's kill-switch refuses it like an install.
      #
      # @return [void]
      # @raise [IndexRefreshError] if brew update fails
      sig { void }
      def refresh_index!
        ProvisioningGuard.check!("run brew update", stub_hint: "BrewRepository#refresh_index!")
        _out, err, success = brew(["update", "--quiet"])
        raise IndexRefreshError.new(stderr: err) unless success
      end

      # The public formula API did not answer for a core formula.
      class FormulaApiError < StandardError
        extend T::Sig

        # @param name [String] formula name
        # @param code [String] the HTTP status code
        sig { params(name: String, code: String).void }
        def initialize(name:, code:)
          super("#{FORMULA_API}/#{name}.json answered #{code}")
        end
      end

      # Report a brew formula's universe: the spec family's current stable
      # versions, one per member (the Resolver takes the greatest satisfying
      # one under BrewScheme's ordering).
      #
      # The tap scoping the name is the package's source coordinate
      # (PackageId#source). Suffix and tap ride metadata as facts:
      # BrewIntegration rebuilds the install spec from both. Head-only
      # siblings without a stable version are not versions and are skipped.
      #
      # @param id [PackageId] name is the formula name; source is the tap
      # @return [Package] one version per family spec
      # @raise [BrewInfoError] if `brew info` fails for the formula
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        tap = id.source
        infos = tap ? tap_family_infos(id.name, tap) : core_family_infos(id.name)

        versions = infos
          .select { |info| info.dig("versions", "stable") }
          .map { |info| version_from(info, tap) }
        Package.new(id: id, versions: versions)
      end

      private

      # A core formula's family, as brew reports it: the bare spec's
      # versioned_formulae siblings first, the bare spec last.
      #
      # @param name [String] formula name
      # @return [Array<Hash>] brew info for each family member
      # @raise [BrewInfoError] if `brew info` fails for the formula
      sig { params(name: String).returns(T::Array[T::Hash[String, T.untyped]]) }
      def core_family_infos(name)
        base_info = T.must(brew_info_all([name]).first)
        family = T.let(base_info["versioned_formulae"] || [], T::Array[String])
        sibling_infos = family.empty? ? [] : brew_info_all(family)
        sibling_infos + [base_info]
      end

      # A tap formula's family, read from the tap's own formula list. Brew
      # computes versioned_formulae for core through the API and reports an
      # empty family for a third-party tap formula, so `ruby@4.0.5`'s
      # siblings are invisible to `brew info`; `brew tap-info --json` lists
      # every formula the tap carries. The bare spec is optional — a tap
      # may publish only `name@exact` files — and sits last when present.
      #
      # @param name [String] bare formula name
      # @param tap [String] tap slug
      # @return [Array<Hash>] brew info for each family member
      # @raise [BrewInfoError] if the tap cannot be read or carries no member
      sig { params(name: String, tap: String).returns(T::Array[T::Hash[String, T.untyped]]) }
      def tap_family_infos(name, tap)
        members = tap_formula_names(tap).select { |member| member == name || member.start_with?("#{name}@") }
        siblings, bare = members.partition { |member| member != name }
        specs = (siblings + bare).map { |member| build_formula_spec(member, tap) }
        raise BrewInfoError, "#{tap} carries no formula #{name} or #{name}@*" if specs.empty?

        brew_info_all(specs)
      end

      # The short names of every formula a tap carries, registering the tap
      # first when this machine has never tapped it — resolving a
      # `tap:`-scoped formula on a fresh host requires the tap to be present.
      #
      # @param tap [String] tap slug
      # @return [Array<String>] formula names without the tap prefix
      # @raise [BrewInfoError] if the tap cannot be read or registered
      sig { params(tap: String).returns(T::Array[String]) }
      def tap_formula_names(tap)
        info = tap_info(tap)
        unless info["installed"]
          raise BrewInfoError, "brew tap #{tap} failed" unless register_tap(tap)

          info = tap_info(tap)
        end
        T.let(info["formula_names"] || [], T::Array[String]).map { |full| full.delete_prefix("#{tap}/") }
      end

      # @param tap [String] tap slug
      # @return [Hash] parsed `brew tap-info --json` for the tap
      # @raise [BrewInfoError] if the command fails
      sig { params(tap: String).returns(T::Hash[String, T.untyped]) }
      def tap_info(tap)
        out, _err, success = brew(["tap-info", "--json", tap])
        raise BrewInfoError, "brew tap-info --json #{tap} failed" unless success

        JSON.parse(out).first
      end

      # One family member's facts as a version: its stable version string,
      # every bottle it publishes — each tag a platform, each bottle the
      # platform's artifact — and the @suffix from its own spec name.
      #
      # Brew fetches bottles itself, so the artifacts are a record of what is
      # published rather than something dev downloads: with every bottle in
      # the version, the pin the Resolver mints is the same whichever machine
      # writes it. The version carries no digest of its own — a single hash
      # would again be one machine's bottle.
      #
      # @param info [Hash] parsed brew info JSON for one formula
      # @param tap [String, nil] tap slug from the id
      # @return [PackageVersion]
      sig { params(info: T::Hash[String, T.untyped], tap: T.nilable(String)).returns(PackageVersion) }
      def version_from(info, tap)
        bottles = bottle_files(info)
        suffix = info["name"].to_s.split("@", 2)[1]

        metadata = {}
        metadata["tap"] = tap if tap
        metadata["version_suffix"] = suffix if suffix
        tap_commit = info["tap_git_head"]
        metadata[TAP_COMMIT] = tap_commit if tap_commit
        metadata["format"] = bottles.key?(IMAGE_BOTTLE_TAG) ? FORMAT_BOTTLE : FORMAT_SOURCE

        PackageVersion.new(
          version: info["versions"]["stable"],
          platforms: bottles.keys,
          # No commit (brew reported no tap_git_head) is no source: nothing
          # a host could install exactly this version from.
          source: tap_commit.nil? ? nil : self.class.source_at(tap, tap_commit.to_s),
          artifacts: bottles.transform_values { |file| artifact_from(file) },
          metadata: metadata,
          # brew installs formula dependencies itself.
          declarations: Declarations::ToolOwned.new,
        )
      end

      # @param file [Hash] one bottle entry: its "url" and "sha256"
      # @return [Artifact]
      sig { params(file: T::Hash[String, T.untyped]).returns(Artifact) }
      def artifact_from(file)
        Artifact.new(uri: file["url"].to_s, digest: "SHA256=#{file["sha256"]}")
      end

      # Build a brew formula spec: [tap/]name.
      #
      # @param name [String] formula name (possibly @-suffixed already)
      # @param tap [String, nil] tap slug
      # @return [String]
      sig { params(name: String, tap: T.nilable(String)).returns(String) }
      def build_formula_spec(name, tap)
        tap ? "#{tap}/#{name}" : name
      end

      # Query `brew info --json=v1` for one or more formulae in a single call.
      #
      # @param formulae [Array<String>] formula specs
      # @return [Array<Hash>] parsed JSON info, one entry per formula
      # @raise [BrewInfoError] if the command fails
      sig { params(formulae: T::Array[String]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def brew_info_all(formulae)
        out, _err, success = brew(["info", "--json=v1", *formulae])
        raise BrewInfoError, "brew info --json=v1 #{formulae.join(" ")} failed" unless success

        JSON.parse(out)
      end

      # @param tap [String] tap slug (e.g. "xcodesorg/made")
      # @return [Boolean] whether `brew tap` succeeded
      sig { params(tap: String).returns(T::Boolean) }
      def register_tap(tap)
        _out, _err, success = brew(["tap", tap])
        success
      end

      # Spawn brew under READ_ENV — the one place the repository runs it,
      # so no query can forget the env (see the class doc).
      #
      # @param args [Array<String>] brew's argv
      # @return [Array(String, String, Boolean)] stdout, stderr, success?
      sig { params(args: T::Array[String]).returns([String, String, T::Boolean]) }
      def brew(args)
        out, err, status = T.unsafe(Open3).capture3(READ_ENV, "brew", *args)
        # success? is nil (not false) when the process didn't exit normally,
        # e.g. it was killed by a signal — coerce that to a failure.
        [out, err, status.success? || false]
      end

      # Every bottle a formula publishes, by tag, in a stable order. A tap
      # formula's brew info reads the formula source and lists them all; a
      # core formula's brew info lists only this machine's bottle, so core
      # reads the public formula API instead — one call per formula.
      #
      # @param info [Hash] parsed brew info JSON for one formula
      # @return [Hash{String => Hash}] bottle tag => its "url" and "sha256"
      # @raise [FormulaApiError] if the API does not answer for a core formula
      sig { params(info: T::Hash[String, T.untyped]).returns(T::Hash[String, T::Hash[String, T.untyped]]) }
      def bottle_files(info)
        listing = info["tap"] == CORE_TAP ? api_formula(info["name"].to_s) : info
        files = T.let(listing.dig("bottle", "stable", "files") || {}, T::Hash[String, T::Hash[String, T.untyped]])
        files.sort.to_h
      end

      # A core formula's document from the public formula API.
      #
      # @param name [String] formula name
      # @return [Hash] parsed formula JSON
      # @raise [FormulaApiError] if the API does not answer 2xx
      sig { params(name: String).returns(T::Hash[String, T.untyped]) }
      def api_formula(name)
        response = Net::HTTP.get_response(URI("#{FORMULA_API}/#{name}.json"))
        raise FormulaApiError.new(name:, code: response.code.to_s) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(T.must(response.body))
      end
    end
  end
end
