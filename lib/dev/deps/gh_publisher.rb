# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/lifecycle/channel"
require "dev/lifecycle/gh"
require "dev/lifecycle/git_state"
require "dev/lifecycle/github_heads"
require "dev/lifecycle/github_releases"
require "dev/lifecycle/head_strategy"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/release_tag"
require "dev/lifecycle/series"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require_relative "../value_equality"
require_relative "tool_closure"

module Dev
  module Deps
    # The write side of the gh integration: the `deploy gh` channel a
    # project gets by declaring it (Registry::Reach::Declaration). The
    # destination is the project's own repo on the forge — where `release`
    # already puts the bytes — and what a deploy moves there is the
    # channel's head alone: the series tag `v<major>` of the release's
    # series, to the release's commit, and GitHub's latest designation
    # when that series is the newest one deployed. The release is the
    # bytes; this publisher writes no notes, no assets, no version tag.
    #
    # Releases only: a head points at a release, so a working artifact
    # from the store is refused; the channel is reached with `dev deploy
    # gh --release <version>`. Immutable releases only: a head is what
    # every follower installs, so the release it names must be one the
    # forge has frozen (`immutable: true`, set by the repository's
    # immutable-releases setting at the cut); a mutable one is refused,
    # naming the setting.
    #
    # Separate from GhRepository, the read side: a follower resolving a
    # pin and a deploy moving a pointer share nothing but the forge.
    #
    # The channel's head is pointed: the series tag is what a follower of
    # the series (`~> 1` on a host's stream, `@v1` in a workflow) resolves,
    # and this publisher is what moves it — forward on a deploy, back when
    # an earlier release of the series is deployed again. The latest
    # designation follows the newest deployed series only, so a 1.x patch
    # deployed after 2.0 is live moves `v1` and leaves `latest` alone.
    #
    # A tree this channel receives that ships its `dependencies.rb` and
    # `deps.lock` is installed self-contained by every follower
    # (ToolClosure): dev converges its dependencies into the tree and
    # writes a launcher per `exe/`. Whether the tree is complete for that
    # is this publisher's to say at `dev package` (#accept!), each refusal
    # naming the gap — once released, the tree is immutable and the
    # install's refusal would fire on an agent host instead.
    class GhPublisher
      extend T::Sig
      include Lifecycle::Publisher

      # A shipment from the store: a head cannot point at a working artifact.
      class WorkingArtifactError < RuntimeError; end

      # The release is not immutable: its tag and assets could change
      # under every follower of the head.
      class MutableReleaseError < RuntimeError; end

      # The tree about to be archived ships a self-contained tree's markers
      # but not what installing one needs.
      class IncompleteTreeError < RuntimeError
        extend T::Sig

        # @param channel [Lifecycle::Channel] the channel refusing
        # @param gaps [Array<String>] what the tree lacks, as ToolClosure names it
        sig { params(channel: Lifecycle::Channel, gaps: T::Array[String]).void }
        def initialize(channel:, gaps:)
          super("channel '#{channel}' refuses the tree as it would ship: it #{gaps.join("; it ")}")
        end
      end

      # The channel's name: the integration's.
      CHANNEL = "gh"

      # What deploying one release to the channel would move, read from
      # the forge before anything is written: the dry run reports it and
      # `publish` applies it. The rules are here, in one place: the series
      # pointer moves when it is not already at the release's commit; the
      # latest designation moves when the release's series is the newest
      # one with a pointer (its own included), the release is no
      # pre-release (GitHub never designates one latest), and it is not
      # already the latest.
      class Candidate < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :tag, Lifecycle::ReleaseTag
        const :sha, String
        const :facts, Lifecycle::GithubReleases::Facts
        const :heads, Lifecycle::GithubHeads::Heads

        # @return [Series] the release's series
        # @raise [Lifecycle::Series::NotAVersionError] a tag that is not a version belongs to no series
        sig { returns(Lifecycle::Series) }
        def series
          Lifecycle::Series.of(tag.version)
        end

        # @return [Lifecycle::GithubHeads::Pointer, nil] the series' pointer as it stands; nil before its first deploy
        sig { returns(T.nilable(Lifecycle::GithubHeads::Pointer)) }
        def pointer
          heads.pointer(series)
        end

        # @return [Boolean] whether the series tag moves (or is created)
        sig { returns(T::Boolean) }
        def moves_pointer?
          pointer&.sha != sha
        end

        # @return [Boolean] whether the release's series is the newest with a pointer, once this deploy has given it one
        sig { returns(T::Boolean) }
        def newest?
          newest = heads.newest_series
          newest.nil? || series.major >= newest.major
        end

        # @return [Boolean] whether the latest designation moves to the release
        sig { returns(T::Boolean) }
        def designates_latest?
          newest? && !facts.prerelease && heads.latest != tag
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [tag, sha, facts, heads]
        end
      end

      # @param project_root [Pathname] the checkout `gh` resolves the repo from
      # @param releases [Lifecycle::GithubReleases] the release archive the release's facts are read from
      # @param heads [Lifecycle::GithubHeads] the heads, read and moved
      sig { params(project_root: Pathname, releases: Lifecycle::GithubReleases, heads: Lifecycle::GithubHeads).void }
      def initialize(
        project_root:,
        releases: Lifecycle::GithubReleases.new(gh: Lifecycle::Gh.new(root: project_root)),
        heads: Lifecycle::GithubHeads.new(gh: Lifecycle::Gh.new(root: project_root))
      )
        @project_root = project_root
        @releases = releases
        @heads = heads
      end

      # Move the release's series head, and the latest designation when
      # the series is the newest deployed.
      #
      # @param shipments [Array<Lifecycle::Shipment>] a release's archives; the first names the release
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track] what the refusal of a working artifact names
      # @param scratch [Pathname] unused: nothing is materialised
      # @return [Lifecycle::Receipt] what moved, and the followers it reaches as the hint
      # @raise [WorkingArtifactError]
      # @raise [MutableReleaseError]
      # @raise [Lifecycle::Series::NotAVersionError]
      # @raise [Lifecycle::GithubReleases::Error] the release's facts could not be read
      # @raise [Lifecycle::GithubHeads::Error] the heads could not be read or moved
      sig do
        override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname)
          .returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        _ = scratch
        candidate = candidate(shipments, channel:, track:)
        raise MutableReleaseError, "deploy #{channel} refuses #{candidate.tag}: #{mutable_reason(candidate)}" unless candidate.facts.immutable

        moved = candidate.moves_pointer? || candidate.designates_latest?
        move!(candidate)
        Lifecycle::Receipt.new(summary: describe(candidate), hint: moved ? hint(candidate) : nil)
      end

      # The heads as they stand and the candidate: what `--dry-run` reports.
      #
      # @param shipments [Array<Lifecycle::Shipment>]
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [Array<String>] the heads line, the candidate line, and the refusal a mutable release would meet
      # @raise [WorkingArtifactError]
      # @raise [Lifecycle::Series::NotAVersionError]
      # @raise [Lifecycle::GithubReleases::Error]
      # @raise [Lifecycle::GithubHeads::Error]
      sig { override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track).returns(T::Array[String]) }
      def preview(shipments, channel:, track:)
        candidate = candidate(shipments, channel:, track:)
        lines = [heads_line(candidate.heads), "Candidate: #{describe(candidate)}"]
        lines << "Refused: #{mutable_reason(candidate)}" unless candidate.facts.immutable
        lines
      end

      # Pointed: the series tag and the latest designation are the pointers.
      sig { override.returns(Lifecycle::HeadStrategy) }
      def head_strategy
        Lifecycle::HeadStrategy::Pointed
      end

      # GitHub's latest designation is this channel's head: it follows
      # the newest deployed series, so `deploy gh` moves it and the cut
      # leaves it alone.
      sig { override.returns(T::Boolean) }
      def owns_release_designation?
        true
      end

      # A tree shipping a self-contained tree's markers must be complete
      # for the install every follower runs (ToolClosure#gaps); a plain
      # asset is accepted as it is.
      #
      # @param tree [Pathname] the tree as it will ship
      # @param channel [Lifecycle::Channel]
      # @return [void]
      # @raise [IncompleteTreeError] naming the channel and every gap
      sig { override.params(tree: Pathname, channel: Lifecycle::Channel).void }
      def accept!(tree, channel:)
        gaps = ToolClosure.new(tree:).gaps
        raise IncompleteTreeError.new(channel:, gaps:) unless gaps.empty?
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s
        CHANNEL
      end

      private

      # The candidate: the release the shipments are of, its facts and
      # the heads as the forge holds them now.
      #
      # @param shipments [Array<Lifecycle::Shipment>] non-empty, as the verb selects
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [Candidate]
      # @raise [WorkingArtifactError]
      sig { params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track).returns(Candidate) }
      def candidate(shipments, channel:, track:)
        release = release_of(shipments, channel:, track:)
        Candidate.new(tag: release.tag, sha: release.sha, facts: @releases.facts(release.tag), heads: @heads.read)
      end

      # The release the shipments are of.
      #
      # @param shipments [Array<Lifecycle::Shipment>]
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [Lifecycle::Provenance::Release]
      # @raise [WorkingArtifactError]
      sig do
        params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track).returns(Lifecycle::Provenance::Release)
      end
      def release_of(shipments, channel:, track:)
        shipment = T.must(shipments.first)
        provenance = shipment.provenance
        case provenance
        when Lifecycle::Provenance::Release then provenance
        when Lifecycle::Provenance::Store
          raise WorkingArtifactError,
            "deploy #{channel} received #{shipment} from the store (the #{track} track): a head points at a release, " \
              "never at a working artifact — cut one with `dev release <version>`, then `dev deploy #{channel} --release <version>`"
        else
          # simplecov:disable — the sealed provenance has no other variant;
          # T.absurd keeps the static proof.
          T.absurd(provenance)
          # simplecov:enable
        end
      end

      # The writes the candidate calls for, pointer first: a latest
      # designation on a series whose tag did not move would name a
      # release no follower is at.
      #
      # @param candidate [Candidate]
      # @return [void]
      # @raise [Lifecycle::GithubHeads::Error]
      sig { params(candidate: Candidate).void }
      def move!(candidate)
        if candidate.moves_pointer?
          candidate.pointer ? @heads.point!(candidate.series, candidate.sha) : @heads.create!(candidate.series, candidate.sha)
        end
        @heads.designate_latest!(candidate.tag) if candidate.designates_latest?
      end

      # @param candidate [Candidate]
      # @return [String] why a mutable release is refused, naming the setting
      sig { params(candidate: Candidate).returns(String) }
      def mutable_reason(candidate)
        "#{candidate.tag}'s release is mutable (immutable: false), so its tag and assets could change under every follower of " \
          "#{candidate.series} — enable immutable releases on the repository (#{Lifecycle::GithubReleases::IMMUTABLE_RELEASES_SETTING}) " \
          "before the next `dev release`; " \
          "a release already cut stays mutable"
      end

      # What the deploy moves, as the receipt and the dry run both say it.
      #
      # @param candidate [Candidate]
      # @return [String]
      sig { params(candidate: Candidate).returns(String) }
      def describe(candidate)
        "#{pointer_clause(candidate)}; #{latest_clause(candidate)}"
      end

      # @param candidate [Candidate]
      # @return [String] the series tag's move: new, from where, or already there
      sig { params(candidate: Candidate).returns(String) }
      def pointer_clause(candidate)
        pointer = candidate.pointer
        return "#{candidate.series} already at #{candidate.tag}" unless candidate.moves_pointer?

        at = "#{candidate.series} → #{candidate.tag} (#{short(candidate.sha)})"
        pointer.nil? ? "#{at}, new" : "#{at}, from #{name(candidate.heads, pointer.sha)}"
      end

      # @param candidate [Candidate]
      # @return [String] the latest designation's move, or why it stays
      sig { params(candidate: Candidate).returns(String) }
      def latest_clause(candidate)
        latest = candidate.heads.latest
        return "latest untouched — a pre-release is never latest" if candidate.facts.prerelease
        return "latest #{latest ? "stays #{latest}" : "untouched"} — #{candidate.heads.newest_series} is the newest series" unless candidate.newest?
        return "latest already #{candidate.tag}" if latest == candidate.tag

        "latest → #{candidate.tag}"
      end

      # @param heads [Lifecycle::GithubHeads::Heads]
      # @return [String] every series pointer and the latest designation as they stand
      sig { params(heads: Lifecycle::GithubHeads::Heads).returns(String) }
      def heads_line(heads)
        pointers = heads.pointers.map { |pointer| "#{pointer.series} → #{name(heads, pointer.sha)}" }
        "Heads: #{pointers.empty? ? "none" : pointers.join(", ")}; latest #{heads.latest || "none"}"
      end

      # A commit as a pointer names it: the release tags cut there, then
      # the short sha; the sha alone when no release was cut there.
      #
      # @param heads [Lifecycle::GithubHeads::Heads]
      # @param sha [String]
      # @return [String]
      sig { params(heads: Lifecycle::GithubHeads::Heads, sha: String).returns(String) }
      def name(heads, sha)
        tags = heads.releases_at(sha)
        tags.empty? ? short(sha) : "#{tags.join("/")} (#{short(sha)})"
      end

      # @param sha [String]
      # @return [String]
      sig { params(sha: String).returns(String) }
      def short(sha)
        T.must(sha[0, Lifecycle::GitState::SHORT_SHA_LENGTH])
      end

      # @param candidate [Candidate]
      # @return [String] who the move reaches
      sig { params(candidate: Candidate).returns(String) }
      def hint(candidate)
        "Followers of #{candidate.series} (~> #{candidate.series.major}, @#{candidate.series}) take #{candidate.tag} from here"
      end
    end
  end
end
