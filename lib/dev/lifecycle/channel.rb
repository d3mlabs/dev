# typed: strict
# frozen_string_literal: true

require_relative "build"
require_relative "build_pattern"
require_relative "publisher_spec"

module Dev
  module Lifecycle
    # One destination `deploy` ships to (dev#192, K5): a `deploy` child in
    # dev.yml, or a channel the lock contributes (dev#422) — its name, the
    # builds it **accepts** (`targets:`, a list of build patterns in the
    # one grammar) and its **protocol** (the PublisherSpec: the child's
    # `run:` line, or an integration's publisher). The accept set is the
    # channel's statement of what may reach it — a Windows box takes
    # `cellbound-3d-win64`, any config, so dev builds reach it; a store
    # that takes release builds only says `cellbound-3d-win64-release`. A
    # build outside the set is shipped only under `--force`; a config is
    # never implied by the channel.
    #
    # An integration channel may carry **options** — the mapping under the
    # channel's own name on the `deploy` child (`steam: { app: 480, depots:
    # … }`), namespaced the way an integration builder's target options
    # are (dev#192, K1) — which are the publisher's vocabulary, not dev's:
    # the channel carries them as the YAML delivered them and the
    # publisher parses and validates them (dev#426). A script channel has
    # none: its `run:` owns whatever it needs.
    #
    # Owns the invariant that a channel accepts something: a channel with
    # an empty accept set could ship nothing and would be a typo kept.
    class Channel < T::Struct
      extend T::Sig

      # `targets:` on the channel lists no pattern.
      class EmptyAcceptSetError < ArgumentError; end

      # What `dev help deploy` shows beside a channel declared without `desc`.
      NO_DESCRIPTION = "(no description)"

      Options = T.type_alias { T::Hash[String, T.untyped] }

      const :name, String
      const :desc, String, default: NO_DESCRIPTION
      # In declaration order; the order the artifacts ship in.
      const :accepts, T::Array[BuildPattern]
      const :publisher, PublisherSpec
      # The publisher's options as dev.yml delivered them; empty for a
      # script channel and for an integration channel configured by its
      # accept set alone.
      const :options, Options, default: {}

      # @param name [String] the `deploy` child's key
      # @param accepts [Array<BuildPattern>] the `targets:` patterns, non-empty
      # @param publisher [PublisherSpec] the protocol as declared
      # @param desc [String]
      # @param options [Hash{String => Object}] the publisher's options
      # @raise [EmptyAcceptSetError]
      sig { params(name: String, accepts: T::Array[BuildPattern], publisher: PublisherSpec, desc: String, options: Options).void }
      def initialize(name:, accepts:, publisher:, desc: NO_DESCRIPTION, options: {})
        super
        raise EmptyAcceptSetError, "channel '#{name}': `targets:` lists no build — name the builds it accepts" if accepts.empty?
      end

      # Every build the channel accepts, in accept order, each once.
      #
      # @return [Array<Build>]
      sig { returns(T::Array[Build]) }
      def builds
        accepts.flat_map(&:builds).uniq
      end

      # Whether a build is inside the accept set.
      #
      # @param build [Build]
      # @return [Boolean]
      sig { params(build: Build).returns(T::Boolean) }
      def accepts?(build)
        accepts.any? { |pattern| pattern.matches?(build) }
      end

      # The accept set with every platform spelled out and the config axis
      # left as declared — what `deploy` ships **one artifact per**: a
      # platform is the destination's fact, a config the operator's choice
      # (`--config`, or the one artifact the store holds). Each once, in
      # accept order.
      #
      # @return [Array<BuildPattern>]
      sig { returns(T::Array[BuildPattern]) }
      def artifact_patterns
        accepts.flat_map(&:per_platform).uniq
      end

      sig { returns(String) }
      def to_s
        name
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(Channel) && name == other.name && desc == other.desc && accepts == other.accepts &&
          publisher == other.publisher && options == other.options
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [Channel, name, desc, accepts, publisher, options].hash
      end
    end
  end
end
