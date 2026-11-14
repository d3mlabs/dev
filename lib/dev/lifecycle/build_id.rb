# typed: strict
# frozen_string_literal: true

require "time"
require_relative "git_state"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The provenance stamp of a packaged build: `<semver>+<sha>`, or
    # `<semver>+<sha>.dirty.<utc>` for a tree with uncommitted changes, or
    # `<semver>+unknown.<utc>` outside a checkout. The part after `+` follows
    # semver's build-metadata grammar, so the id sorts as a version; the UTC
    # instant tells two dirty packagings apart.
    class BuildId
      extend T::Sig
      include Dev::ValueEquality::Derived

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
      def to_s
        @value
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [@value]
      end
    end
  end
end
