# typed: strict
# frozen_string_literal: true

require_relative "tag_scheme"

module Dev
  module Deps
    # Git ref semantics (:cmake): the universe's versions are resolved SHAs,
    # each carrying the ref it resolved from as a fact, and the requirement
    # reads that fact — never the SHA, which is a repository fact the scheme
    # cannot derive and carries no order. A tag or branch name is an exact
    # ask (`tag: "v1.3.2"`, `branch: "main"`); a range reads the refs that
    # are versions, as TagScheme does over gh tags. Commit pins are not
    # requirements at all — a SHA is an address into the continuous space,
    # declared as the revision and lifted by GitRepository#at without any
    # scheme running.
    class GitScheme < TagScheme
      extend T::Sig

      # The fact a version carries its ref under.
      REF = "ref"

      protected

      # @param version [PackageVersion] a resolved SHA with its ref fact
      # @return [String] the ref name; empty for a version with none
      sig { override.params(version: PackageVersion).returns(String) }
      def coordinate(version)
        version.metadata[REF].to_s
      end
    end
  end
end
