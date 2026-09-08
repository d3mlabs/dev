# typed: strict
# frozen_string_literal: true

require "open3"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Reports git-hosted dependencies: the discrete universe is the remote's
    # refs, the continuous space is its commit SHAs.
    #
    # find enumerates every tag and branch head via one `git ls-remote` call —
    # each version is the resolved full SHA carrying the ref it resolved from
    # as a fact, which is what GitScheme's tag/branch matching selects on.
    # Commit SHAs are unreachable by enumeration (`ls-remote` lists refs,
    # never reachable commits), so a commit pin arrives as the declaration's
    # revision and is lifted by at — pure, no network: a full SHA is
    # self-certifying as an address, and existence surfaces at fetch time.
    # Git SHAs are identifiers, not integrity hashes — digest is nil.
    class GitRepository < Repository
      extend T::Sig

      class RefResolutionError < PackageNotFoundError; end

      # Report a git dependency's universe: every tag and branch head,
      # resolved to full SHAs.
      #
      # @param id [PackageId] source is the git remote URL
      # @param probe [String, nil] ignored (refs are enumerable)
      # @return [Package] one version per ref, the ref riding as a fact
      # @raise [RefResolutionError] if the remote's refs cannot be listed
      sig { override.params(id: PackageId, probe: T.nilable(String)).returns(Package) }
      def find(id, probe: nil)
        repo_url = T.must(id.source)
        refs = enumerate_refs(repo_url)
        raise RefResolutionError, "no refs listable for #{id.name} at #{repo_url}" if refs.empty?

        Package.new(
          id: id,
          versions: refs.map do |ref, sha|
            PackageVersion.new(
              version: sha,
              metadata: { "repo" => repo_url, "ref" => ref },
              # A checked-out source tree carries no manifest dev reads;
              # consumers declare what they need alongside it.
              declarations: Declarations::Resolved.new([]),
            )
          end,
        )
      end

      # Lift a commit SHA into a version. Pure — no network: the SHA is the
      # version, the author already chose it, and a bad address surfaces at
      # fetch time exactly like a force-pushed ref would.
      #
      # @param id [PackageId] source is the git remote URL
      # @param revision [String] full 40-char commit SHA (DSL-validated)
      # @return [PackageVersion]
      sig { override.params(id: PackageId, revision: String).returns(PackageVersion) }
      def at(id, revision)
        PackageVersion.new(
          version: revision,
          metadata: { "repo" => T.must(id.source) },
          declarations: Declarations::Resolved.new([]),
        )
      end

      private

      # List every tag and branch head with its commit SHA, in one call.
      #
      # Annotated tags list twice — the tag object and a peeled "<ref>^{}"
      # line pointing at the commit; the peeled SHA wins, because the commit
      # is what a checkout materializes.
      #
      # @param repo [String] git remote URL
      # @return [Hash{String => String}] ref name (unprefixed) -> full SHA
      # @raise [RefResolutionError] if ls-remote fails
      sig { params(repo: String).returns(T::Hash[String, String]) }
      def enumerate_refs(repo)
        out, err, status = Open3.capture3("git", "ls-remote", "--tags", "--heads", repo)
        raise RefResolutionError, "git ls-remote failed for #{repo}: #{err}" unless status.success?

        out.lines.each_with_object({}) do |line, refs|
          sha, refname = line.split
          next unless sha && refname

          peeled = refname.end_with?("^{}")
          name = refname.delete_suffix("^{}").sub(%r{\Arefs/(tags|heads)/}, "")
          refs[name] = sha if peeled || !refs.key?(name)
        end
      end
    end
  end
end
