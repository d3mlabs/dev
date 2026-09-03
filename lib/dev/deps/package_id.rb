# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # Identity of a package within its integration's universe: constraint-free
    # and version-free.
    #
    # This is the "which package are we talking about" half of the domain,
    # separated from "which versions exist" (Package), "what does the project
    # want" (DependencyDeclaration) and "what did we choose" (Dependency). It
    # is the Resolver's resolved-set key, which is why identity includes the
    # integration: two ecosystems can each publish a package named "ffi", and
    # keying on the bare name would silently collapse them.
    #
    # A plain value class rather than Data.define: `source` carries a default,
    # and Data.define with a keyword-args initialize override is rejected by
    # Sorbet at `typed: strict` (error 4010).
    #
    # See docs/deps-architecture.md for the four-type ontology this belongs to.
    class PackageId
      extend T::Sig

      # @return [Symbol] the integration whose universe this package lives in
      sig { returns(Symbol) }
      attr_reader :integration

      # @return [String] the package's name within that universe
      sig { returns(String) }
      attr_reader :name

      # @return [String, nil] source coordinates for source-based packages
      sig { returns(T.nilable(String)) }
      attr_reader :source

      # @param integration [Symbol] :bundler, :ficsit, :cmake, …
      # @param name [String] the package's name within that integration
      # @param source [String, nil] source coordinates for source-based
      #   packages (a git repo URL); nil for registry-backed types, where the
      #   name alone identifies the package
      sig { params(integration: Symbol, name: String, source: T.nilable(String)).void }
      def initialize(integration:, name:, source: nil)
        @integration = integration
        @name = name
        @source = source
        freeze
      end

      # @param other [Object]
      # @return [Boolean] whether other identifies the same package
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(PackageId)

        [integration, name, source] == [other.integration, other.name, other.source]
      end
      alias_method :eql?, :==

      # @return [Integer] hash code, so ids work as Hash keys
      sig { returns(Integer) }
      def hash
        [self.class, integration, name, source].hash
      end

      # @return [String] "integration/name", with the source appended when the
      #   package is source-based
      sig { returns(String) }
      def to_s
        source ? "#{integration}/#{name} (#{source})" : "#{integration}/#{name}"
      end
    end
  end
end
