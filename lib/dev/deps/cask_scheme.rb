# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Homebrew cask semantics (:cask): no requirement at all. Homebrew
    # publishes no versions for casks and versioned casks are distinct cask
    # names (`temurin@21`), so the name is the whole coordinate — the
    # universe is one unversioned entry and `Any` is the only ask it can
    # answer. Anything else is refused before the universe is read, naming
    # the way to say it.
    class CaskScheme < VersionScheme
      extend T::Sig

      # @param requirement [Requirement]
      # @return [Boolean] Any alone
      sig { override.params(requirement: Requirement).returns(T::Boolean) }
      def supports?(requirement)
        requirement.any?
      end

      # @return [String]
      sig { override.returns(String) }
      def supported
        "no version: Homebrew publishes none for casks, and a versioned cask is its own name (`brew \"temurin@21\", cask: true`)"
      end

      # @param version [PackageVersion] the one unversioned entry
      # @param requirement [Requirement] Any, the only supported form
      # @return [Boolean]
      sig { override.params(version: PackageVersion, requirement: Requirement).returns(T::Boolean) }
      def satisfies?(version, requirement)
        requirement.any?
      end

      # @param versions [Array<PackageVersion>]
      # @return [Array<PackageVersion>] the same versions, order untouched —
      #   a cask universe is a singleton
      sig { override.params(versions: T::Array[PackageVersion]).returns(T::Array[PackageVersion]) }
      def sort(versions)
        versions.dup
      end
    end
  end
end
