# typed: strict
# frozen_string_literal: true

require_relative "version_scheme"

module Dev
  module Deps
    # Git ref constraint semantics (:cmake): the constraint names a ref —
    # "tag" or "branch" — and the universe's versions are resolved SHAs
    # carrying the ref they resolved from as a fact.
    #
    # A ref constraint matches the version's "ref" fact, never the version
    # string: the SHA a ref points at is a repository fact the scheme cannot
    # derive. Commit pins are not constraints at all — a SHA is an address
    # into the continuous space, declared as the revision and lifted by
    # GitRepository#at without any scheme running.
    class GitScheme < VersionScheme
      extend T::Sig

      # @param version [PackageVersion] a candidate (version is the resolved
      #   SHA, "ref" rides its metadata)
      # @param constraint [Hash] declaration constraint; "tag" or "branch"
      # @return [Boolean]
      sig { override.params(version: PackageVersion, constraint: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def satisfies?(version, constraint)
        ref = constraint["tag"] || constraint["branch"]
        return true if ref.nil?

        version.metadata["ref"].to_s == ref.to_s
      end

      # @param versions [Array<String>] resolved SHAs
      # @return [Array<String>] the same versions, order untouched — SHAs
      #   carry no order
      sig { override.params(versions: T::Array[String]).returns(T::Array[String]) }
      def sort(versions)
        versions.dup
      end
    end
  end
end
