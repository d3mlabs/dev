# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/build"
require "dev/lifecycle/build_pattern"
require "dev/lifecycle/channel"
require "dev/lifecycle/track"

module Dev
  module Deps
    # What a project's `deploy steam` channel says of its Steam app (dev#192
    # K5, dev#426): the options under the channel's `steam:` key in dev.yml,
    # in Steamworks' own words —
    #
    #   steam:
    #     app: 480                                   # the AppID
    #     depots:                                    # one DepotID per build pattern
    #       cellbound-3d-steamworks-win64: 481
    #       cellbound-3d-steamworks-linux64: 482
    #     branches: { testing: beta, live: default } # optional: the branch per track
    #
    # The app and its depots are the destination's facts, which is why they
    # live on the channel and in no build (K0); the branch is the track's
    # — a working artifact goes to the testing branch (`beta` unless named),
    # a release's archive to the live one (`default` unless named). Parsed
    # here, once, at the start of a deploy; the publisher holds typed
    # values from then on. The dev.yml boundary for this vocabulary, so
    # the messages name the key and the fix.
    class SteamChannelOptions < T::Struct
      extend T::Sig

      # `steam:` lacks a key the publisher cannot do without.
      class MissingOptionError < ArgumentError; end

      # A `steam:` value of the wrong shape (an app id that is not a
      # positive integer, depots that are not a mapping).
      class InvalidOptionError < ArgumentError; end

      # A shipped build matches no depot pattern — nothing says which depot
      # takes it.
      class NoDepotError < ArgumentError; end

      # A shipped build matches two depot patterns — two depots claim it.
      class AmbiguousDepotError < ArgumentError; end

      KEY = "steam"
      APP_KEY = "app"
      DEPOTS_KEY = "depots"
      BRANCHES_KEY = "branches"

      # Steam's name for the branch every player is on; it cannot be set
      # live from a build script (Steamworks: "that must be done through
      # the App Admin panel").
      DEFAULT_BRANCH = "default"

      DEFAULT_BRANCHES = T.let(
        { Lifecycle::Track::Testing => "beta", Lifecycle::Track::Live => DEFAULT_BRANCH }.freeze,
        T::Hash[Lifecycle::Track, String],
      )

      const :app, Integer
      # In declaration order: the pattern a build must match → its DepotID.
      const :depots, T::Hash[Lifecycle::BuildPattern, Integer]
      const :branches, T::Hash[Lifecycle::Track, String]

      class << self
        extend T::Sig

        # Read the channel's `steam:` options.
        #
        # @param channel [Lifecycle::Channel] the `deploy steam` channel
        # @return [SteamChannelOptions]
        # @raise [MissingOptionError]
        # @raise [InvalidOptionError]
        # @raise [Lifecycle::BuildPattern::UnknownTargetError] and the
        #   grammar's other errors, for a depot pattern no accepted target spells
        # @raise [Lifecycle::UnknownTrackError] for a branch keyed by no track
        sig { params(channel: Lifecycle::Channel).returns(SteamChannelOptions) }
        def parse(channel)
          options = channel.options
          raw_depots = fetch(options, DEPOTS_KEY, channel)
          unless raw_depots.is_a?(Hash) && !raw_depots.empty?
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{DEPOTS_KEY}:` must map each accepted build to its DepotID " \
                "(`cellbound-3d-steamworks-win64: 481`), got #{raw_depots.inspect}"
          end

          targets = channel.accepts.map(&:target).uniq
          depots = raw_depots.to_h do |pattern, depot|
            [Lifecycle::BuildPattern.parse(pattern.to_s, targets), positive_integer(depot, "#{DEPOTS_KEY}: #{pattern}", channel)]
          end
          new(
            app: positive_integer(fetch(options, APP_KEY, channel), APP_KEY, channel),
            depots:,
            branches: DEFAULT_BRANCHES.merge(branches(options[BRANCHES_KEY], channel)),
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
              "channel 'deploy #{channel}': `#{KEY}: #{key}:` is missing — the steam publisher needs the AppID and a DepotID " \
                "per accepted build (d3mlabs/dev#192)"
          end
        end

        # @param raw [Object] an id as YAML delivered it (an Integer, or its digits)
        # @param what [String] the key, for the message
        # @param channel [Lifecycle::Channel]
        # @return [Integer]
        # @raise [InvalidOptionError]
        sig { params(raw: T.untyped, what: String, channel: Lifecycle::Channel).returns(Integer) }
        def positive_integer(raw, what, channel)
          id = T.let(Integer(raw.to_s, 10, exception: false), T.nilable(Integer))
          return id if id&.positive?

          raise InvalidOptionError, "channel 'deploy #{channel}': `#{KEY}: #{what}:` must be a Steam id (a positive integer), got #{raw.inspect}"
        end

        # @param raw [Object] the `branches:` value, absent or a mapping of track → branch
        # @param channel [Lifecycle::Channel]
        # @return [Hash{Lifecycle::Track => String}] the tracks named
        # @raise [InvalidOptionError]
        # @raise [Lifecycle::UnknownTrackError]
        sig { params(raw: T.untyped, channel: Lifecycle::Channel).returns(T::Hash[Lifecycle::Track, String]) }
        def branches(raw, channel)
          return {} if raw.nil?
          unless raw.is_a?(Hash) && raw.values.all? { |branch| branch.is_a?(String) && !branch.empty? }
            raise InvalidOptionError,
              "channel 'deploy #{channel}': `#{KEY}: #{BRANCHES_KEY}:` must map a track to a branch name " \
                "(`{ testing: beta, live: default }`), got #{raw.inspect}"
          end

          raw.to_h { |track, branch| [Lifecycle::Track.parse(track.to_s), branch] }
        end
      end

      # The depot a build ships to.
      #
      # @param build [Lifecycle::Build]
      # @return [Integer] the DepotID
      # @raise [NoDepotError]
      # @raise [AmbiguousDepotError]
      sig { params(build: Lifecycle::Build).returns(Integer) }
      def depot_for(build)
        matching = depots.select { |pattern, _| pattern.matches?(build) }
        case matching.size
        when 1 then T.must(matching.values.first)
        when 0
          raise NoDepotError,
            "no depot for #{build}: `#{KEY}: #{DEPOTS_KEY}:` names #{depots.keys.join(", ")} — add a DepotID for it"
        else
          raise AmbiguousDepotError,
            "#{build} matches #{matching.size} depot patterns (#{matching.keys.join(", ")}) — make `#{KEY}: #{DEPOTS_KEY}:` " \
              "name one depot per build"
        end
      end

      # The branch a track ships to.
      #
      # @param track [Lifecycle::Track]
      # @return [String]
      sig { params(track: Lifecycle::Track).returns(String) }
      def branch_for(track)
        branches.fetch(track)
      end

      # Whether a branch is Steam's default one — the one a build script
      # cannot set live.
      #
      # @param branch [String]
      # @return [Boolean]
      sig { params(branch: String).returns(T::Boolean) }
      def default_branch?(branch)
        branch == DEFAULT_BRANCH
      end
    end
  end
end
