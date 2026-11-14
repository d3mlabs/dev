# typed: strict
# frozen_string_literal: true

require "dev/lifecycle/track"

module Dev
  module Deps
    # SMR's `VersionStabilities` — how a published version is offered:
    # `release` is what every player gets, `beta` and `alpha` are what a
    # player opts into per mod in the Mod Manager. The ficsit publisher
    # maps dev's two tracks onto two of the three: an artifact from the
    # store ships on the testing track and lands as a beta, a release's
    # archive ships on the live track as a release. Alpha is never emitted;
    # beta is the state testers already look in.
    class FicsitStability < T::Enum
      extend T::Sig

      enums do
        Alpha = new("alpha")
        Beta = new("beta")
        Release = new("release")
      end

      class << self
        extend T::Sig

        # The stability a track ships as.
        #
        # @param track [Lifecycle::Track]
        # @return [FicsitStability]
        sig { params(track: Lifecycle::Track).returns(FicsitStability) }
        def for_track(track)
          track.live? ? Release : Beta
        end
      end

      # The id, as the API spells it.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
