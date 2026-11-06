# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require_relative "cli/flag"
require_relative "cli/parsed_args"

module Dev
  # What `dev deploy <channel>` makes of its argv (dev#192, K4, K5): the
  # artifacts that ship, selected from the store — never built, never
  # guessed. The channel's accept set, narrowed by the positional when one
  # is given (`[BUILD]`, a name or a pattern in the grammar), is spelled
  # out per platform (Channel#artifact_patterns): one artifact ships per
  # entry, and the config axis is the operator's choice — `--config`
  # chooses; without it the store must hold exactly one candidate, and
  # two is a refusal listing them (cellbound-3d#181's "unique match or
  # explicit"). A build outside the accept set ships only under `--force`;
  # a missing artifact is refused with the `dev package` that would make
  # it; a stale one — not packaged from a clean tree at this commit — is
  # refused unless `--allow-stale`, and then reported. The verb's flags
  # are consumed here and never reach the protocol.
  #
  # The channel, the project's targets and the store are fixed for a run
  # and constructor-owned; the args and the tree's state are per call.
  class DeploySelector
    extend T::Sig

    CONFIG_FLAG = "--config"
    ALLOW_STALE_FLAG = "--allow-stale"
    FORCE_FLAG = "--force"

    FLAGS = T.let(
      [
        Cli::Flag.new(CONFIG_FLAG, takes_value: true, desc: "the config to ship when the store holds several of an accepted build"),
        Cli::Flag.new(ALLOW_STALE_FLAG, desc: "ship an artifact not packaged from a clean tree at this commit"),
        Cli::Flag.new(FORCE_FLAG, desc: "ship BUILD although the channel does not accept it"),
      ].freeze,
      T::Array[Cli::Flag],
    )

    # What ships: the artifacts in accept order, which of them are stale
    # (allowed through by `--allow-stale`), and the track they land on —
    # decided by where they came from (K5): the store holds working
    # artifacts, so a selection from it is always for the testing track;
    # the live track is the release source's (`--release`, dev#425).
    class Selection < T::Struct
      const :artifacts, T::Array[Lifecycle::Artifact]
      const :stale, T::Array[Lifecycle::Artifact]
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

    # The store holds no artifact of an accepted build.
    class MissingArtifactError < RuntimeError; end

    # The store holds several artifacts of an accepted build (one per
    # config) and nothing says which ships.
    class AmbiguousArtifactError < RuntimeError; end

    # A selected artifact was not packaged from a clean tree at this
    # commit, and `--allow-stale` was not given.
    class StaleArtifactError < RuntimeError; end

    # @param channel [Lifecycle::Channel] the destination
    # @param targets [Array<Lifecycle::Target>] the project's targets, the positional's grammar
    # @param store [Lifecycle::Store] where the artifacts are
    sig { params(channel: Lifecycle::Channel, targets: T::Array[Lifecycle::Target], store: Lifecycle::Store).void }
    def initialize(channel:, targets:, store:)
      @channel = channel
      @targets = targets
      @store = store
    end

    # The artifacts the args select for the channel.
    #
    # @param args [Cli::ParsedArgs] parsed against FLAGS (and the verb's own)
    # @param state [Lifecycle::GitState] the tree now, what staleness is read against
    # @return [Selection]
    # @raise [TooManyBuildsError]
    # @raise [ForceWithoutBuildError]
    # @raise [OutsideAcceptSetError]
    # @raise [NoAcceptedConfigError]
    # @raise [MissingArtifactError]
    # @raise [AmbiguousArtifactError]
    # @raise [StaleArtifactError]
    # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the grammar's
    #   other errors, for a positional no target admits
    # @raise [Lifecycle::UnknownConfigError] for a `--config` outside the id set
    # @raise [Lifecycle::Store::MisnamedArtifactError, Lifecycle::Manifest::MalformedManifestError]
    sig { params(args: Cli::ParsedArgs, state: Lifecycle::GitState).returns(Selection) }
    def select(args, state:)
      config_id = args.value(CONFIG_FLAG)
      config = config_id && Lifecycle::Config.parse(config_id)
      artifacts = candidates(args).map { |pattern, builds| pick(pattern, builds, config) }
      stale = artifacts.reject { |artifact| artifact.current?(state) }
      unless stale.empty? || args.flag?(ALLOW_STALE_FLAG)
        raise StaleArtifactError,
          "#{stale.map { |artifact| "#{artifact.name} (#{artifact.manifest.build_id})" }.join(", ")} " \
            "#{stale.one? ? "was" : "were"} not packaged from a clean tree at this commit — `dev package` again, " \
            "or #{ALLOW_STALE_FLAG} to ship as is"
      end

      Selection.new(artifacts:, stale:, track: Lifecycle::Track::Testing)
    end

    private

    # What each shipped artifact is chosen from: a per-platform pattern and
    # the builds it admits — the channel's accept set, or the positional's
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
      chosen = config ? builds.select { |build| build.config == config } : builds
      if chosen.empty?
        raise NoAcceptedConfigError,
          "no build of '#{pattern}' has config '#{config}' (candidates: #{builds.map(&:name).join(", ")})"
      end

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
  end
end
