# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Constraint semantics for pinned universes (:brew, :cmake, :gh, :steam,
    # :xcode): the backing service already applied the declared identity
    # constraint while building the universe, so every reported version
    # satisfies, and the reported order stands.
    #
    # These ecosystems' constraints name an identity (a git tag or commit, a
    # release tag, a Steam buildid, an exact Xcode version, a brew formula
    # suffix), not a range over an ordered version set — the repository
    # queries exactly that identity and reports a degenerate (usually
    # singleton) universe. There is nothing left to evaluate or to order.
    class PinnedScheme < VersionScheme
      extend T::Sig

      # @param version [String] any reported version
      # @param constraint [Hash] ignored — already applied by the repository
      # @return [Boolean] always true
      sig { override.params(version: String, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        true
      end

      # @param versions [Array<String>] reported versions
      # @return [Array<String>] the same versions, order untouched
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.dup
      end
    end
  end
end
