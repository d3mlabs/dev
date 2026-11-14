# typed: strict
# frozen_string_literal: true

require_relative "build"
require_relative "build_pattern"
require_relative "publisher_spec"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # One destination `deploy` ships to: a `deploy` child in dev.yml, or a
    # channel the lock contributes. Carries its name, the builds it accepts
    # (`targets:`, a list of build patterns) and its protocol (the
    # PublisherSpec). A build outside the accept set is shipped only under
    # `--force`; a config is never implied by the channel.
    #
    # An integration channel may carry options: the mapping under the
    # channel's own name on the `deploy` child (`steam: { app: 480, … }`).
    # They are the publisher's vocabulary: the channel carries them as the
    # YAML delivered them and the publisher parses and validates them. A
    # script channel has none.
    #
    # Owns the invariant that a channel accepts something.
    class Channel < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

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
      # left as declared. `deploy` ships one artifact per entry. Each once,
      # in accept order.
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

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name, desc, accepts, publisher, options]
      end
    end
  end
end
