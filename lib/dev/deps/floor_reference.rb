# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # The floor of an `image` block as the author asks for it (dev#277): a
    # tagged image in a container registry, `<host>/<repository>:<tag>`.
    #
    # The one place the floor's grammar lives. The DSL parses `from:` into
    # one at the declaration boundary, so a malformed floor is a
    # `dependencies.rb` error where it is written; OciRepository re-reads
    # the declaration's source as one before it talks to the registry, so
    # its contract stands on its own. Both depend on this type, neither on
    # the other (dev#395). The registry's answer is a different type —
    # OciRepository::ResolvedFloor — because what the author asks and what
    # the registry serves change for different reasons.
    #
    # A plain value class rather than Data.define, as PackageId is: a
    # keyword-args initialize override on Data.define is rejected by Sorbet
    # at `typed: strict` (error 4010).
    class FloorReference
      extend T::Sig

      # The source is not `<host>/<repository>:<tag>`.
      class ReferenceError < StandardError; end

      # `<host>/<repository>:<tag>` — the host has a dot or a port (so a bare
      # Hub name is refused: the floor is never a floating `ubuntu:22.04`),
      # the tag is a tag, never a digest.
      REFERENCE = %r{\A(?<host>[a-z0-9.-]+(?::\d+)?)/(?<repository>[a-z0-9._/-]+):(?<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\z}

      # @return [String] the registry host, with its port when it has one
      sig { returns(String) }
      attr_reader :host

      # @return [String] the repository path under the host
      sig { returns(String) }
      attr_reader :repository

      # @return [String] the tag to resolve
      sig { returns(String) }
      attr_reader :tag

      class << self
        extend T::Sig

        # Parse a floor as written in `dependencies.rb`.
        #
        # @param source [String, nil] the `from:` value, or a declaration's source
        # @return [FloorReference]
        # @raise [ReferenceError] if the source is not `<host>/<repository>:<tag>`
        sig { params(source: T.nilable(String)).returns(FloorReference) }
        def parse(source)
          match = source && REFERENCE.match(source)
          unless match
            raise ReferenceError,
              "#{source.inspect} is not a floor reference — declare `from: \"<registry>/<repository>:<tag>\"` " \
                "(a registry host, a repository, a tag to resolve; dev locks the digest)"
          end

          new(host: T.must(match[:host]), repository: T.must(match[:repository]), tag: T.must(match[:tag]))
        end
      end

      # @param host [String] the registry host
      # @param repository [String] the repository path under the host
      # @param tag [String] the tag to resolve
      sig { params(host: String, repository: String, tag: String).void }
      def initialize(host:, repository:, tag:)
        @host = host
        @repository = repository
        @tag = tag
        freeze
      end

      # @return [String] the image less its tag: `ghcr.io/d3mlabs/unreal-engine-build-base`
      sig { returns(String) }
      def name = "#{host}/#{repository}"

      # The registry prefix an image derived from this floor publishes
      # beside: everything before the repository's last path segment —
      # `ghcr.io/d3mlabs` for `ghcr.io/d3mlabs/unreal-engine-build-base`.
      #
      # @return [String]
      sig { returns(String) }
      def registry = [host, *T.must(repository.split("/")[0...-1])].join("/")

      # @return [String] the reference as written: `<host>/<repository>:<tag>`
      sig { returns(String) }
      def to_s = "#{name}:#{tag}"

      # @param other [Object]
      # @return [Boolean] whether other names the same floor
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(FloorReference)

        [host, repository, tag] == [other.host, other.repository, other.tag]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so references work as Hash keys
      sig { returns(Integer) }
      def hash
        [self.class, host, repository, tag].hash
      end
    end
  end
end
