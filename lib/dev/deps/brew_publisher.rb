# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/lifecycle/channel"
require "dev/lifecycle/gh"
require "dev/lifecycle/git_state"
require "dev/lifecycle/github_releases"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/release_tag"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require_relative "formula_file"
require_relative "tap"
require_relative "tap_clone"

module Dev
  module Deps
    # The write side of the brew integration (dev#192 K3, K5; dev#429): the
    # `deploy brew` channel a project gets by pinning a formula from a tap
    # (`ruby "4.0.6"` reaches it). Its rule is parameterless — **one
    # target, one formula, named alike**: for each shipment, the formula
    # `Formula/<build>.rb` of the tap gets `url` = that build's release
    # asset and `sha256` = the digest `release.json` records, and the
    # rewritten formulas are committed and pushed together. dev's own two
    # targets are the first consumer: `dev-core` and `dev` are two
    # formulas pointing at two assets of one release, where the earlier
    # `bin/release.rb` pointed both at the repo's source tarball and
    # authored the `dev` payload as heredocs inside the formula.
    #
    # Releases only: a formula points at a release asset by tag, never at
    # a file in a store, so a working artifact from the store — the
    # testing track — is refused; the channel is reached with `dev deploy
    # brew --release <version>`. The formula must exist: dev rewrites a
    # formula's stable spec, it never authors one — the dependency edges,
    # the install block and the caveats are the tap maintainer's.
    #
    # The destination is the tap the lock pins from — the one its brew
    # pins name under `tap:` — and the publisher writes to its own clone
    # of it in the channel's scratch (TapClone), never to the brew
    # prefix's tap or a clone beside the checkout. The asset urls are the
    # forge's own answer (GithubReleases#asset_url). The receipt is the
    # tap's commit, and its hint the upgrade line the operator runs next
    # — what `bin/release.rb` closed on — so `deploy`'s epilogue ends on
    # it without knowing brew (Receipt#hint, dev#514).
    #
    # Separate from BrewRepository, the read side, although the plan's
    # built-ins are "their repository objects when the write side shares
    # the read side's client and auth": brew's read side is `brew info`
    # and its write side is git over a clone and `gh` for the asset url —
    # nothing shared, so the two change for different reasons.
    class BrewPublisher
      extend T::Sig
      include Lifecycle::Publisher

      # A shipment from the store: a formula cannot point at a working artifact.
      class WorkingArtifactError < RuntimeError; end

      # The lock pins no formula from a tap, so there is no tap to write to.
      class NoTapError < RuntimeError; end

      # The lock pins formulae from several taps; the channel writes to one.
      class AmbiguousTapError < RuntimeError; end

      # The channel's name: the integration's.
      CHANNEL = "brew"

      # @param project_root [Pathname] the checkout `gh` resolves the release's repo from
      # @param taps [Array<Tap>] the taps the lock pins formulae from (Registry.publishers' context)
      # @param releases [Lifecycle::GithubReleases] the release archive the asset urls are read from
      sig { params(project_root: Pathname, taps: T::Array[Tap], releases: Lifecycle::GithubReleases).void }
      def initialize(project_root:, taps:, releases: Lifecycle::GithubReleases.new(gh: Lifecycle::Gh.new(root: project_root)))
        @project_root = project_root
        @taps = taps
        @releases = releases
      end

      # Point each shipment's formula at its release asset, commit and push.
      #
      # @param shipments [Array<Lifecycle::Shipment>] a release's archives, in the channel's accept order
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track] what the refusal of a working artifact names
      # @param scratch [Pathname] where the tap's clone lives
      # @return [Lifecycle::Receipt] the tap's commit and the formulas it moved, or that nothing moved; the upgrade line as its hint
      # @raise [WorkingArtifactError]
      # @raise [NoTapError]
      # @raise [AmbiguousTapError]
      # @raise [TapClone::FormulaMissingError]
      # @raise [FormulaFile::NoStableSpecError]
      # @raise [Lifecycle::GithubReleases::Error] an asset the release does not carry, a refused read
      # @raise [Lifecycle::Git::CommandFailedError] the tap unreachable, or a push it refuses
      sig do
        override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname)
          .returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        tag = release_tag(shipments, channel:, track:)
        tap = destination
        clone = TapClone.new(tap:, dir: clone_dir(scratch, tap))
        clone.sync!

        rewritten = shipments.filter_map { |shipment| point(clone.formula(shipment.name), shipment, tag) }
        names = shipments.map(&:name).join(", ")
        hint = upgrade_hint(tap, shipments)
        return Lifecycle::Receipt.new(summary: "#{tap.name} already points at #{tag}: #{names}", hint:) if rewritten.empty?

        clone.commit!(message: "#{rewritten.map(&:name).join(", ")}: #{tag.version}", files: rewritten)
        clone.push!
        Lifecycle::Receipt.new(summary: "#{tap.name}@#{clone.head[0, Lifecycle::GitState::SHORT_SHA_LENGTH]}: #{rewritten.map(&:name).join(", ")} → #{tag}", hint:)
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s = CHANNEL

      private

      # What the operator runs next: the tap's formulas of the shipments,
      # fully qualified, after a `brew update` that fetches the push.
      #
      # @param tap [Tap]
      # @param shipments [Array<Lifecycle::Shipment>]
      # @return [String]
      sig { params(tap: Tap, shipments: T::Array[Lifecycle::Shipment]).returns(String) }
      def upgrade_hint(tap, shipments)
        "To update locally: brew update && brew upgrade #{shipments.map { |shipment| "#{tap.name}/#{shipment.name}" }.join(" ")}"
      end

      # The tag the shipments are a release of.
      #
      # @param shipments [Array<Lifecycle::Shipment>] non-empty, as the verb selects
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [Lifecycle::ReleaseTag]
      # @raise [WorkingArtifactError]
      sig { params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track).returns(Lifecycle::ReleaseTag) }
      def release_tag(shipments, channel:, track:)
        shipment = T.must(shipments.first)
        provenance = shipment.provenance
        case provenance
        when Lifecycle::Provenance::Release then provenance.tag
        when Lifecycle::Provenance::Store
          raise WorkingArtifactError,
            "deploy #{channel} received #{shipment} from the store (the #{track} track): a formula points at a release asset, " \
              "never at a working artifact — cut one with `dev release <version>`, then `dev deploy #{channel} --release <version>`"
        else
          # simplecov:disable — the sealed provenance has no other variant;
          # T.absurd keeps the static proof.
          T.absurd(provenance)
          # simplecov:enable
        end
      end

      # The one tap the lock pins from.
      #
      # @return [Tap]
      # @raise [NoTapError]
      # @raise [AmbiguousTapError]
      sig { returns(Tap) }
      def destination
        case @taps.length
        when 1 then T.must(@taps.first)
        when 0
          raise NoTapError,
            "deploy #{CHANNEL} publishes to the tap the lock pins formulae from, and this lock pins from none — depend on a formula " \
              "of the tap that carries the project's formulas in dependencies.rb, then `dev deps update`"
        else
          raise AmbiguousTapError,
            "deploy #{CHANNEL} publishes to the one tap the lock pins formulae from, and this lock pins from " \
              "#{@taps.length} (#{@taps.map(&:name).join(", ")}) — the channel cannot pick between them"
        end
      end

      # Where the tap's clone lives in the scratch: brew's own layout,
      # `<user>/homebrew-<repo>`.
      #
      # @param scratch [Pathname]
      # @param tap [Tap]
      # @return [Pathname]
      sig { params(scratch: Pathname, tap: Tap).returns(Pathname) }
      def clone_dir(scratch, tap)
        user, repo = tap.name.split("/", 2)
        scratch / T.must(user) / "homebrew-#{repo}"
      end

      # Point a formula at a shipment's asset, when it does not already.
      #
      # @param formula [FormulaFile]
      # @param shipment [Lifecycle::Shipment] its archive's name is the asset's
      # @param tag [Lifecycle::ReleaseTag]
      # @return [FormulaFile, nil] the formula when it was rewritten
      # @raise [FormulaFile::NoStableSpecError]
      # @raise [Lifecycle::GithubReleases::Error]
      sig { params(formula: FormulaFile, shipment: Lifecycle::Shipment, tag: Lifecycle::ReleaseTag).returns(T.nilable(FormulaFile)) }
      def point(formula, shipment, tag)
        url = @releases.asset_url(tag, shipment.archive.basename.to_s)
        spec = FormulaFile::StableSpec.new(url:, sha256: shipment.archive_sha256)
        return nil if formula.stable_spec == spec

        formula.write_stable_spec(spec)
        formula
      end
    end
  end
end
