# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/build"
require "dev/lifecycle/build_pattern"
require "dev/lifecycle/channel"
require "dev/lifecycle/track"
require_relative "../value_equality"

module Dev
  module Deps
    # What a project's `deploy egs` channel says of its Epic Games Store
    # product: the options under the channel's `egs:` key in dev.yml, in
    # the Dev Portal's own words:
    #
    #   egs:
    #     organization: o-abc123                   # the Organization ID
    #     product: p-def456                        # the Product ID
    #     artifacts:                               # one Artifact per build pattern
    #       cellbound-3d-win64:
    #         id: a-789xyz                         # the Artifact ID
    #         launch: Cellbound3D.exe              # the executable, relative to the build root
    #         args: ""                             # optional: the launch command line
    #     labels: { testing: Testing, live: Live } # optional: the label per track
    #
    # The organization, product and artifacts are the destination's facts;
    # the label is the track's. `Live` is the one label players see, so a
    # release's archive takes it and a working artifact a label of its own
    # (`Testing` unless named); labelled, so Epic's cleanup does not delete
    # it after a week. The client id and secret are credentials, not
    # options. Parsed once at the start of a deploy.
    class EgsChannelOptions < T::Struct
      extend T::Sig

      # `egs:` lacks a key the publisher cannot do without.
      class MissingOptionError < ArgumentError; end

      # An `egs:` value of the wrong shape.
      class InvalidOptionError < ArgumentError; end

      # A shipped build matches no artifact pattern.
      class NoArtifactError < ArgumentError; end

      # A shipped build matches two artifact patterns.
      class AmbiguousArtifactError < ArgumentError; end

      # One Epic artifact: a binary stream of the product, for one platform.
      class Artifact < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :id, String
        # The app to launch, relative to the build root (`Game.exe`,
        # `Game.app/Contents/MacOS/Game`).
        const :launch, String
        const :args, String, default: ""

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [id, launch, args]
        end
      end

      KEY = "egs"
      ORGANIZATION_KEY = "organization"
      PRODUCT_KEY = "product"
      ARTIFACTS_KEY = "artifacts"
      LABELS_KEY = "labels"
      ARTIFACT_ID_KEY = "id"
      ARTIFACT_LAUNCH_KEY = "launch"
      ARTIFACT_ARGS_KEY = "args"

      # The label Epic's launcher serves to players.
      LIVE_LABEL = "Live"

      DEFAULT_LABELS = T.let(
        { Lifecycle::Track::Testing => "Testing", Lifecycle::Track::Live => LIVE_LABEL }.freeze,
        T::Hash[Lifecycle::Track, String],
      )

      const :organization, String
      const :product, String
      # In declaration order: the pattern a build must match → its artifact.
      const :artifacts, T::Hash[Lifecycle::BuildPattern, Artifact]
      const :labels, T::Hash[Lifecycle::Track, String]

      class << self
        extend T::Sig

        # Read the channel's `egs:` options.
        #
        # @param channel [Lifecycle::Channel] the `deploy egs` channel
        # @return [EgsChannelOptions]
        # @raise [MissingOptionError]
        # @raise [InvalidOptionError]
        # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the
        #   grammar's other errors, for an artifact pattern no accepted target spells
        # @raise [Lifecycle::UnknownTrackError] for a label keyed by no track
        sig { params(channel: Lifecycle::Channel).returns(EgsChannelOptions) }
        def parse(channel)
          options = channel.options
          raw_artifacts = fetch(options, ARTIFACTS_KEY, channel)
          unless raw_artifacts.is_a?(Hash) && !raw_artifacts.empty?
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{ARTIFACTS_KEY}:` must map each accepted build to its artifact " \
                "(`cellbound-3d-win64: { id: …, launch: Game.exe }`), got #{raw_artifacts.inspect}"
          end

          targets = channel.accepts.map(&:target).uniq
          artifacts = raw_artifacts.to_h do |pattern, raw|
            [Lifecycle::BuildPattern.parse(pattern.to_s, targets), artifact(raw, pattern.to_s, channel)]
          end
          new(
            organization: identifier(fetch(options, ORGANIZATION_KEY, channel), ORGANIZATION_KEY, channel),
            product: identifier(fetch(options, PRODUCT_KEY, channel), PRODUCT_KEY, channel),
            artifacts:,
            labels: DEFAULT_LABELS.merge(labels(options[LABELS_KEY], channel)),
          )
        end

        private

        # @param options [Hash{String => Object}]
        # @param key [String]
        # @param channel [Lifecycle::Channel]
        # @return [Object]
        # @raise [MissingOptionError]
        sig { params(options: Lifecycle::Channel::Options, key: String, channel: Lifecycle::Channel).returns(T.untyped) }
        def fetch(options, key, channel)
          options.fetch(key) do
            raise MissingOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{key}:` is missing — the egs publisher needs the Organization ID, " \
                "the Product ID and an artifact per accepted build"
          end
        end

        # @param raw [Object] an id as YAML delivered it
        # @param what [String] the key, for the message
        # @param channel [Lifecycle::Channel]
        # @return [String]
        # @raise [InvalidOptionError]
        sig { params(raw: T.untyped, what: String, channel: Lifecycle::Channel).returns(String) }
        def identifier(raw, what, channel)
          return raw if raw.is_a?(String) && !raw.strip.empty?

          raise InvalidOptionError, "channel 'deploy #{channel}': `#{KEY}: #{what}:` must be an id from the Dev Portal, got #{raw.inspect}"
        end

        # @param raw [Object] one `artifacts:` entry as YAML delivered it
        # @param pattern [String] the entry's key, for messages
        # @param channel [Lifecycle::Channel]
        # @return [Artifact]
        # @raise [InvalidOptionError]
        sig { params(raw: T.untyped, pattern: String, channel: Lifecycle::Channel).returns(Artifact) }
        def artifact(raw, pattern, channel)
          unless raw.is_a?(Hash)
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{ARTIFACTS_KEY}: #{pattern}:` must be a mapping with `#{ARTIFACT_ID_KEY}:` " \
                "and `#{ARTIFACT_LAUNCH_KEY}:`, got #{raw.inspect}"
          end

          entry = raw.transform_keys(&:to_s)
          args = entry.fetch(ARTIFACT_ARGS_KEY, "")
          unless args.is_a?(String)
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{ARTIFACTS_KEY}: #{pattern}: #{ARTIFACT_ARGS_KEY}:` must be a string, got #{args.inspect}"
          end

          Artifact.new(
            id: identifier(entry[ARTIFACT_ID_KEY], "#{ARTIFACTS_KEY}: #{pattern}: #{ARTIFACT_ID_KEY}", channel),
            launch: identifier(entry[ARTIFACT_LAUNCH_KEY], "#{ARTIFACTS_KEY}: #{pattern}: #{ARTIFACT_LAUNCH_KEY}", channel),
            args:,
          )
        end

        # @param raw [Object] the `labels:` value, absent or a mapping of track → label
        # @param channel [Lifecycle::Channel]
        # @return [Hash{Lifecycle::Track => String}] the tracks named
        # @raise [InvalidOptionError]
        # @raise [Lifecycle::UnknownTrackError]
        sig { params(raw: T.untyped, channel: Lifecycle::Channel).returns(T::Hash[Lifecycle::Track, String]) }
        def labels(raw, channel)
          return {} if raw.nil?
          unless raw.is_a?(Hash) && raw.values.all? { |label| label.is_a?(String) && !label.empty? }
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{LABELS_KEY}:` must map a track to a label " \
                "(`{ testing: Testing, live: Live }`), got #{raw.inspect}"
          end

          raw.to_h { |track, label| [Lifecycle::Track.parse(track.to_s), label] }
        end
      end

      # The artifact a build ships to.
      #
      # @param build [Lifecycle::Build]
      # @return [Artifact]
      # @raise [NoArtifactError]
      # @raise [AmbiguousArtifactError]
      sig { params(build: Lifecycle::Build).returns(Artifact) }
      def artifact_for(build)
        matching = artifacts.select { |pattern, _| pattern.matches?(build) }
        case matching.size
        when 1 then T.must(matching.values.first)
        when 0
          raise NoArtifactError,
            "no artifact for #{build}: `#{KEY}: #{ARTIFACTS_KEY}:` names #{artifacts.keys.join(", ")} — add one for it"
        else
          raise AmbiguousArtifactError,
            "#{build} matches #{matching.size} artifact patterns (#{matching.keys.join(", ")}) — make `#{KEY}: #{ARTIFACTS_KEY}:` " \
              "name one artifact per build"
        end
      end

      # The label a track ships under.
      #
      # @param track [Lifecycle::Track]
      # @return [String]
      sig { params(track: Lifecycle::Track).returns(String) }
      def label_for(track)
        labels.fetch(track)
      end
    end
  end
end
