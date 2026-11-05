# typed: strict
# frozen_string_literal: true

require_relative "build"
require_relative "build_pattern"
require_relative "publisher_spec"

module Dev
  module Lifecycle
    # One destination `deploy` ships to (dev#192, K5): a `deploy` child in
    # dev.yml — its name, the builds it **accepts** (`targets:`, a list of
    # build patterns in the one grammar) and its **protocol** (the
    # PublisherSpec: the child's `run:` line today; an integration's
    # publisher with dev#422). The accept set is the channel's statement of
    # what may reach it — a Windows box takes `cellbound-3d-win64`, any
    # config, so dev builds reach it; a store that takes release builds
    # only says `cellbound-3d-win64-release`. A build outside the set is
    # shipped only under `--force`; a config is never implied by the
    # channel.
    #
    # Owns the invariant that a channel accepts something: a channel with
    # an empty accept set could ship nothing and would be a typo kept.
    class Channel < T::Struct
      extend T::Sig

      # `targets:` on the channel lists no pattern.
      class EmptyAcceptSetError < ArgumentError; end

      const :name, String
      const :desc, String, default: "(no description)"
      # In declaration order; the order the artifacts ship in.
      const :accepts, T::Array[BuildPattern]
      const :publisher, PublisherSpec

      # @param name [String] the `deploy` child's key
      # @param accepts [Array<BuildPattern>] the `targets:` patterns, non-empty
      # @param publisher [PublisherSpec] the protocol as declared
      # @param desc [String]
      # @raise [EmptyAcceptSetError]
      sig { params(name: String, accepts: T::Array[BuildPattern], publisher: PublisherSpec, desc: String).void }
      def initialize(name:, accepts:, publisher:, desc: "(no description)")
        super
        raise EmptyAcceptSetError, "channel '#{name}': `targets:` lists no build — name the builds it accepts" if accepts.empty?
      end

      # Every build the channel accepts, in accept order, each once.
      #
      # @return [Array<Build>]
      sig { returns(T::Array[Build]) }
      def builds = accepts.flat_map(&:builds).uniq

      # Whether a build is inside the accept set.
      #
      # @param build [Build]
      # @return [Boolean]
      sig { params(build: Build).returns(T::Boolean) }
      def accepts?(build) = accepts.any? { |pattern| pattern.matches?(build) }

      # The accept set with every platform spelled out and the config axis
      # left as declared — what `deploy` ships **one artifact per**: a
      # platform is the destination's fact, a config the operator's choice
      # (`--config`, or the one artifact the store holds). Each once, in
      # accept order.
      #
      # @return [Array<BuildPattern>]
      sig { returns(T::Array[BuildPattern]) }
      def artifact_patterns = accepts.flat_map(&:per_platform).uniq

      sig { returns(String) }
      def to_s = name

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Channel) && name == other.name && desc == other.desc && accepts == other.accepts && publisher == other.publisher
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [Channel, name, desc, accepts, publisher].hash
    end
  end
end
