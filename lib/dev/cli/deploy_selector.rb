# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "flag"
require_relative "parsed_args"

module Dev
  module Cli
    # What `dev deploy <channel>` makes of its argv (dev#192, K4, K5): the
    # shipments — one archive per build — selected from a **source**, never
    # built, never guessed. The channel's accept set, narrowed by the
    # positional when one is given (`[BUILD]`, a name or a pattern in the
    # grammar), is spelled out per platform (Channel#artifact_patterns): one
    # archive ships per entry, and the config axis is the operator's choice —
    # `--config` chooses; without it the source must hold exactly one
    # candidate, and two is a refusal listing them (cellbound-3d#181's
    # "unique match or explicit"). A build outside the accept set ships only
    # under `--force`. The verb's flags are consumed here and never reach the
    # protocol.
    #
    # The source decides the track (K5). Without `--release` it is the
    # **store**: working artifacts, the testing track; a missing one is
    # refused with the `dev package` that would make it, a stale one — not
    # packaged from a clean tree at this commit — unless `--allow-stale`, and
    # then reported. With `--release <version>` it is the **release** on the
    # forge (dev#425): its `release.json` says which archives it carries,
    # the selected ones are downloaded and sha-checked (ReleaseArchives), and
    # they ship on the live track; a build the release has no archive of is
    # refused — a release is cut whole or not at all, deploy adds nothing to
    # it — and `--allow-stale` has nothing to allow, a tag being immutable.
    #
    # The channel, the project's targets and the two sources are fixed for a
    # run and constructor-owned; the args and the tree's state are per call.
    class DeploySelector
      extend T::Sig

      CONFIG_FLAG = "--config"
      ALLOW_STALE_FLAG = "--allow-stale"
      FORCE_FLAG = "--force"
      RELEASE_FLAG = "--release"

      FLAGS = T.let(
        [
          Cli::Flag.new(CONFIG_FLAG, takes_value: true, desc: "the config to ship when the source holds several of an accepted build"),
          Cli::Flag.new(RELEASE_FLAG, takes_value: true, desc: "ship the archives of release VERSION, downloaded and verified, on the live track"),
          Cli::Flag.new(ALLOW_STALE_FLAG, desc: "ship an artifact not packaged from a clean tree at this commit"),
          Cli::Flag.new(FORCE_FLAG, desc: "ship BUILD although the channel does not accept it"),
        ].freeze,
        T::Array[Cli::Flag],
      )

      # What ships: the shipments in accept order, which of them are stale
      # (allowed through by `--allow-stale`; none from a release), and the
      # track they land on — decided by where they came from (K5): testing
      # from the store, live from a release.
      class Selection < T::Struct
        const :shipments, T::Array[Lifecycle::Shipment]
        const :stale, T::Array[Lifecycle::Shipment]
        const :track, Lifecycle::Track
      end

      # More than one positional: a deploy names at most one build or pattern.
      class TooManyBuildsError < ArgumentError; end

      # `--force` with no build to force: the flag only widens the positional.
      class ForceWithoutBuildError < ArgumentError; end

      # The positional names no build the channel accepts.
      class OutsideAcceptSetError < ArgumentError; end

      # `--config` leaves no candidate of an accepted build.
      class NoAcceptedConfigError < ArgumentError; end

      # `--allow-stale` beside `--release`: a release's archives are at their
      # tag by construction, so the flag would excuse nothing.
      class AllowStaleWithReleaseError < ArgumentError; end

      # The store holds no artifact of an accepted build.
      class MissingArtifactError < RuntimeError; end

      # The store holds several artifacts of an accepted build (one per
      # config) and nothing says which ships.
      class AmbiguousArtifactError < RuntimeError; end

      # A selected artifact was not packaged from a clean tree at this
      # commit, and `--allow-stale` was not given.
      class StaleArtifactError < RuntimeError; end

      # The release carries no archive of an accepted build.
      class NotInReleaseError < RuntimeError; end

      # The release carries several archives of an accepted build (one per
      # config) and nothing says which ships.
      class AmbiguousReleaseArchiveError < RuntimeError; end

      # @param channel [Lifecycle::Channel] the destination
      # @param targets [Array<Lifecycle::Target>] the project's targets, the positional's grammar
      # @param store [Lifecycle::Store] where the working artifacts are
      # @param release_archives [Lifecycle::ReleaseArchives] where a release's are
      sig do
        params(
          channel: Lifecycle::Channel,
          targets: T::Array[Lifecycle::Target],
          store: Lifecycle::Store,
          release_archives: Lifecycle::ReleaseArchives,
        ).void
      end
      def initialize(channel:, targets:, store:, release_archives:)
        @channel = channel
        @targets = targets
        @store = store
        @release_archives = release_archives
      end

      # The shipments the args select for the channel.
      #
      # @param args [Cli::ParsedArgs] parsed against FLAGS (and the verb's own)
      # @param state [Lifecycle::GitState] the tree now, what staleness is read against
      # @return [Selection]
      # @raise [TooManyBuildsError]
      # @raise [ForceWithoutBuildError]
      # @raise [OutsideAcceptSetError]
      # @raise [NoAcceptedConfigError]
      # @raise [AllowStaleWithReleaseError]
      # @raise [MissingArtifactError]
      # @raise [AmbiguousArtifactError]
      # @raise [StaleArtifactError]
      # @raise [NotInReleaseError]
      # @raise [AmbiguousReleaseArchiveError]
      # @raise [Lifecycle::ReleaseTag::InvalidVersionError] for a `--release` that names no tag
      # @raise [Lifecycle::ReleaseArchives::NoReleaseError, Lifecycle::ReleaseArchives::TagMismatchError,
      #   Lifecycle::ReleaseArchives::ChecksumMismatchError, Lifecycle::GithubReleases::Error] reading the release
      # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the grammar's
      #   other errors, for a positional no target admits
      # @raise [Lifecycle::UnknownConfigError] for a `--config` outside the id set
      # @raise [Lifecycle::Store::MisnamedArtifactError, Lifecycle::Manifest::MalformedManifestError]
      sig { params(args: Cli::ParsedArgs, state: Lifecycle::GitState).returns(Selection) }
      def select(args, state:)
        config_id = args.value(CONFIG_FLAG)
        config = config_id && Lifecycle::Config.parse(config_id)
        version = args.value(RELEASE_FLAG)
        return from_store(candidates(args), config, args.flag?(ALLOW_STALE_FLAG), state) if version.nil?

        if args.flag?(ALLOW_STALE_FLAG)
          raise AllowStaleWithReleaseError, "#{ALLOW_STALE_FLAG} excuses nothing under #{RELEASE_FLAG}: a release's archives are at their tag"
        end

        from_release(candidates(args), config, Lifecycle::ReleaseTag.new(version))
      end

      private

      # The store's selection: one artifact per entry, staleness read against
      # the tree, the testing track.
      #
      # @param candidates [Array<[Lifecycle::BuildPattern, Array<Lifecycle::Build>]>]
      # @param config [Lifecycle::Config, nil] `--config`
      # @param allow_stale [Boolean] `--allow-stale`
      # @param state [Lifecycle::GitState]
      # @return [Selection]
      # @raise [StaleArtifactError]
      sig do
        params(
          candidates: T::Array[[Lifecycle::BuildPattern, T::Array[Lifecycle::Build]]],
          config: T.nilable(Lifecycle::Config),
          allow_stale: T::Boolean,
          state: Lifecycle::GitState,
        ).returns(Selection)
      end
      def from_store(candidates, config, allow_stale, state)
        artifacts = candidates.map { |pattern, builds| pick(pattern, builds, config) }
        stale = artifacts.reject { |artifact| artifact.current?(state) }
        unless stale.empty? || allow_stale
          raise StaleArtifactError,
            "#{stale.map { |artifact| "#{artifact.name} (#{artifact.manifest.build_id})" }.join(", ")} " \
              "#{stale.one? ? "was" : "were"} not packaged from a clean tree at this commit — `dev package` again, " \
              "or #{ALLOW_STALE_FLAG} to ship as is"
        end

        Selection.new(
          shipments: artifacts.map { |artifact| Lifecycle::Shipment.of_artifact(artifact) },
          stale: stale.map { |artifact| Lifecycle::Shipment.of_artifact(artifact) },
          track: Lifecycle::Track::Testing,
        )
      end

      # The release's selection: one of its archives per entry, downloaded
      # and verified, the live track.
      #
      # @param candidates [Array<[Lifecycle::BuildPattern, Array<Lifecycle::Build>]>]
      # @param config [Lifecycle::Config, nil] `--config`
      # @param tag [Lifecycle::ReleaseTag]
      # @return [Selection]
      sig do
        params(
          candidates: T::Array[[Lifecycle::BuildPattern, T::Array[Lifecycle::Build]]],
          config: T.nilable(Lifecycle::Config),
          tag: Lifecycle::ReleaseTag,
        ).returns(Selection)
      end
      def from_release(candidates, config, tag)
        release = @release_archives.manifest(tag)
        entries = candidates.map { |pattern, builds| pick_from_release(pattern, builds, config, release, tag) }
        Selection.new(shipments: @release_archives.fetch(entries, release:, tag:), stale: [], track: Lifecycle::Track::Live)
      end

      # What each shipment is chosen from: a per-platform pattern and the
      # builds it admits — the channel's accept set, or the positional's
      # patterns narrowed to the accepted builds (every build they span under
      # `--force`).
      #
      # @param args [Cli::ParsedArgs]
      # @return [Array<[Lifecycle::BuildPattern, Array<Lifecycle::Build>]>] in accept order
      # @raise [TooManyBuildsError]
      # @raise [ForceWithoutBuildError]
      # @raise [OutsideAcceptSetError]
      sig { params(args: Cli::ParsedArgs).returns(T::Array[[Lifecycle::BuildPattern, T::Array[Lifecycle::Build]]]) }
      def candidates(args)
        if args.positionals.size > 1
          raise TooManyBuildsError, "one build at a time: got #{args.positionals.map(&:inspect).join(", ")}"
        end

        positional = args.positionals.first
        force = args.flag?(FORCE_FLAG)
        if positional.nil?
          raise ForceWithoutBuildError, "#{FORCE_FLAG} ships a build the channel does not accept — name it" if force

          return @channel.artifact_patterns.map { |pattern| [pattern, pattern.builds] }
        end

        asked = Lifecycle::BuildPattern.parse(positional, @targets)
        narrowed = asked.per_platform.filter_map do |pattern|
          builds = force ? pattern.builds : pattern.builds.select { |build| @channel.accepts?(build) }
          [pattern, builds] unless builds.empty?
        end
        return narrowed unless narrowed.empty?

        raise OutsideAcceptSetError,
          "'#{asked}' names no build channel '#{@channel}' accepts (it accepts #{@channel.builds.map(&:name).join(", ")}); " \
            "#{FORCE_FLAG} ships it anyway"
      end

      # The one artifact of a per-platform pattern: among its candidates (the
      # `--config` one when given), the single one the store holds.
      #
      # @param pattern [Lifecycle::BuildPattern] what the artifact is chosen for, for messages
      # @param builds [Array<Lifecycle::Build>] its candidates
      # @param config [Lifecycle::Config, nil] `--config`
      # @return [Lifecycle::Artifact]
      # @raise [NoAcceptedConfigError]
      # @raise [MissingArtifactError]
      # @raise [AmbiguousArtifactError]
      sig do
        params(pattern: Lifecycle::BuildPattern, builds: T::Array[Lifecycle::Build], config: T.nilable(Lifecycle::Config))
          .returns(Lifecycle::Artifact)
      end
      def pick(pattern, builds, config)
        chosen = configured(pattern, builds, config)
        present = chosen.filter_map { |build| @store.artifact(build) }
        case present.size
        when 0
          raise MissingArtifactError,
            "no artifact of '#{pattern}' in the store (#{chosen.map(&:name).join(", ")}) — `dev package #{T.must(chosen.first)}` first; " \
              "deploy never builds"
        when 1 then T.must(present.first)
        else
          raise AmbiguousArtifactError,
            "'#{pattern}' has #{present.size} artifacts in the store: " \
              "#{present.map { |artifact| "#{artifact.name} (#{artifact.manifest.build_id})" }.join(", ")} — #{CONFIG_FLAG} chooses"
        end
      end

      # The one archive of a per-platform pattern in a release: among its
      # candidates (the `--config` one when given), the single one the
      # release carries.
      #
      # @param pattern [Lifecycle::BuildPattern] what the archive is chosen for, for messages
      # @param builds [Array<Lifecycle::Build>] its candidates
      # @param config [Lifecycle::Config, nil] `--config`
      # @param release [Lifecycle::Manifest::Release] what the release carries
      # @param tag [Lifecycle::ReleaseTag] for messages
      # @return [Lifecycle::Manifest::Release::Archive]
      # @raise [NoAcceptedConfigError]
      # @raise [NotInReleaseError]
      # @raise [AmbiguousReleaseArchiveError]
      sig do
        params(
          pattern: Lifecycle::BuildPattern,
          builds: T::Array[Lifecycle::Build],
          config: T.nilable(Lifecycle::Config),
          release: Lifecycle::Manifest::Release,
          tag: Lifecycle::ReleaseTag,
        ).returns(Lifecycle::Manifest::Release::Archive)
      end
      def pick_from_release(pattern, builds, config, release, tag)
        chosen = configured(pattern, builds, config)
        carried = chosen.filter_map { |build| release.archive(build) }
        case carried.size
        when 0
          raise NotInReleaseError,
            "#{tag} carries no archive of '#{pattern}' (#{chosen.map(&:name).join(", ")}); it carries " \
              "#{release.archives.map { |entry| entry.build.name }.join(", ")} — a release ships what `release:` cut into it; deploy adds nothing"
        when 1 then T.must(carried.first)
        else
          raise AmbiguousReleaseArchiveError,
            "#{tag} carries #{carried.size} archives of '#{pattern}': #{carried.map(&:name).join(", ")} — #{CONFIG_FLAG} chooses"
        end
      end

      # The candidates `--config` leaves.
      #
      # @param pattern [Lifecycle::BuildPattern] for messages
      # @param builds [Array<Lifecycle::Build>]
      # @param config [Lifecycle::Config, nil]
      # @return [Array<Lifecycle::Build>]
      # @raise [NoAcceptedConfigError]
      sig do
        params(pattern: Lifecycle::BuildPattern, builds: T::Array[Lifecycle::Build], config: T.nilable(Lifecycle::Config))
          .returns(T::Array[Lifecycle::Build])
      end
      def configured(pattern, builds, config)
        chosen = config ? builds.select { |build| build.config == config } : builds
        return chosen unless chosen.empty?

        raise NoAcceptedConfigError, "no build of '#{pattern}' has config '#{config}' (candidates: #{builds.map(&:name).join(", ")})"
      end
    end
  end
end
