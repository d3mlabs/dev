# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Homebrew constraint semantics (:brew, :cask): the constraint's "version"
    # is a formula *suffix* ("18" selects the llvm@18 formula), not a range
    # over the reported stable versions — brew's own universe treats llvm@18
    # as a distinct formula, so the suffix is the coordinate.
    #
    # The suffix is matched against the version's "version_suffix" fact (the
    # reported stable version, e.g. "18.1.8", is brew's record, not the
    # coordinate). Suffixed formulae are not enumerable — brew answers for
    # one formula spec at a time — so the suffix doubles as the probe.
    class BrewScheme < VersionScheme
      extend T::Sig

      # @param version [PackageVersion] a candidate ("version_suffix" rides
      #   its metadata when the formula spec was suffixed)
      # @param constraint [Hash] declaration constraint; "version" holds the suffix
      # @return [Boolean]
      sig { override.params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        suffix = constraint["version"]
        suffix.nil? || version.metadata["version_suffix"].to_s == suffix.to_s
      end

      # @param versions [Array<String>] reported stable versions
      # @return [Array<String>] the same versions, order untouched — brew
      #   reports one current version per formula spec
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.dup
      end

      # @param constraint [Hash] declaration constraint
      # @return [String, nil] the suffix, for Repository#find's probe
      sig { override.params(constraint: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def pin(constraint)
        suffix = constraint["version"]
        suffix&.to_s
      end
    end
  end
end
