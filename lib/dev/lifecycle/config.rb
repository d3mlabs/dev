# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # An id outside Config's set, at a boundary (dev.yml, a manifest, a
    # build name). The message lists the set so the fix is one edit away.
    # Beside the enum rather than inside it: a T::Enum body may hold only
    # its own values.
    class UnknownConfigError < ArgumentError; end

    # The config axis of a build: one closed set of roles. A target declares
    # the subset it supports; what a role means to the toolchain is the
    # builder's (`dev → Development`, `release → Shipping`). A variant that
    # is conditional compilation (ASan, a demo SKU) is a target, not a config.
    class Config < T::Enum
      extend T::Sig

      enums do
        Debug = new("debug")
        Development = new("dev")
        Release = new("release")
      end

      class << self
        extend T::Sig

        # The config an id names — the deserialization every boundary goes
        # through.
        #
        # @param id [String] a config id as written
        # @return [Config]
        # @raise [UnknownConfigError]
        sig { params(id: String).returns(Config) }
        def parse(id)
          try_deserialize(id) || raise(UnknownConfigError, "unknown config #{id.inspect} (expected #{ids.join(", ")})")
        end

        # Whether a word is a config id — what the build grammar and the
        # target-name rule test a segment against.
        #
        # @param word [String]
        # @return [Boolean]
        sig { params(word: String).returns(T::Boolean) }
        def id?(word)
          !try_deserialize(word).nil?
        end

        # Every id, in declaration order.
        #
        # @return [Array<String>]
        sig { returns(T::Array[String]) }
        def ids
          values.map(&:serialize)
        end
      end

      # The id, for a name or a file.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
