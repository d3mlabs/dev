# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Git ref constraint semantics (:cmake): the constraint names a ref —
    # "commit" (a SHA) or "tag" — and the universe's versions are resolved
    # SHAs carrying the ref they resolved from as a fact.
    #
    # A commit constraint matches the version string itself (the SHA); a tag
    # constraint matches the version's "ref" fact, because the SHA a tag
    # points at is a repository fact the scheme cannot derive. Commits are the
    # canonical non-enumerable coordinate: `git ls-remote` lists refs, never
    # reachable SHAs, so the ref doubles as the probe (see #pin).
    class GitScheme < VersionScheme
      extend T::Sig

      # @param version [PackageVersion] a candidate (version is the resolved SHA)
      # @param constraint [Hash] declaration constraint; "commit" or "tag"
      # @return [Boolean]
      sig { override.params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        ref = pin(constraint)
        return true if ref.nil?

        version.version == ref || version.metadata["ref"].to_s == ref
      end

      # @param versions [Array<String>] resolved SHAs
      # @return [Array<String>] the same versions, order untouched — SHAs
      #   carry no order
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.dup
      end

      # @param constraint [Hash] declaration constraint
      # @return [String, nil] the declared ref, for Repository#find's probe
      sig { override.params(constraint: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def pin(constraint)
        ref = constraint["commit"] || constraint["tag"]
        ref&.to_s
      end
    end
  end
end
