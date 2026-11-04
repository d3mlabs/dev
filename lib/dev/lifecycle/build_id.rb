# typed: strict
# frozen_string_literal: true

require "time"
require_relative "git_state"

module Dev
  module Lifecycle
    # The provenance stamp of a packaged build: `<semver>+<sha>`, or
    # `<semver>+<sha>.dirty.<utc>` for a tree with uncommitted changes, or
    # `<semver>+unknown.<utc>` outside a checkout (lifted from cellbound-3d's
    # `Staging::BuildId`). The build metadata after `+` follows semver's
    # grammar, so the id sorts and compares as a version where one is
    # expected; the UTC instant makes two dirty packagings distinguishable.
    class BuildId
      extend T::Sig

      # A string that is not a build id (a manifest written by something
      # other than dev, or edited).
      class MalformedBuildIdError < ArgumentError; end

      # What a project without a version of its own stamps.
      DEFAULT_SEMVER = "0.0.0"
      UNKNOWN_SHA = "unknown"
      INSTANT_FORMAT = "%Y%m%dT%H%M%SZ"
      INSTANT_PATTERN = /\d{8}T\d{6}Z/
      PATTERN = /\A[^+\s]+\+(?:[0-9a-f]+(?:\.dirty\.#{INSTANT_PATTERN})?|#{UNKNOWN_SHA}\.#{INSTANT_PATTERN})\z/

      class << self
        extend T::Sig

        # The id for a tree in a given state, at an instant.
        #
        # @param state [GitState] the tree's commit and cleanliness
        # @param semver [String] the project's version
        # @param now [Time] the packaging instant (injectable for tests)
        # @return [BuildId]
        sig { params(state: GitState, semver: String, now: Time).returns(BuildId) }
        def derive(state:, semver: DEFAULT_SEMVER, now: Time.now)
          instant = now.utc.strftime(INSTANT_FORMAT)
          sha = state.sha
          metadata = if sha.nil?
            "#{UNKNOWN_SHA}.#{instant}"
          elsif state.dirty
            "#{sha}.dirty.#{instant}"
          else
            sha
          end
          new("#{semver}+#{metadata}")
        end
      end

      # @param value [String] an id as stamped
      # @raise [MalformedBuildIdError]
      sig { params(value: String).void }
      def initialize(value)
        raise MalformedBuildIdError, "#{value.inspect} is not a build id (<semver>+<sha>[.dirty.<utc>])" unless PATTERN.match?(value)

        @value = value
        freeze
      end

      sig { returns(String) }
      def to_s = @value

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other) = other.is_a?(BuildId) && @value == other.to_s

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [BuildId, @value].hash
    end
  end
end
