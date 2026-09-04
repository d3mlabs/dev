# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  module Clone
    # Clones GitHub repos through `gh`, so the fetch rides the user's gh auth
    # (dev is public and carries no credentials of its own — the same doctrine
    # as the learnings cache).
    class GhCloner
      extend T::Sig

      # `gh repo clone` failed (gh missing, unauthenticated, or a git error).
      class CloneFailedError < RuntimeError; end

      # Thin wrapper over the gh CLI boundary. Tests inject a fake.
      class Executor
        extend T::Sig

        # Run argv streaming its output, with the child's stdout redirected
        # to stderr: clone progress belongs with diagnostics, and `dev clone`'s
        # stdout is reserved for the machine payload (the destination path the
        # shell wrapper cds into).
        #
        # @param argv [Array<String>]
        # @return [Boolean] whether the command exited 0
        sig { params(argv: String).returns(T::Boolean) }
        def system(*argv)
          T.unsafe(Kernel).system(*argv, out: $stderr) ? true : false
        end
      end

      # @param executor [Executor] CLI boundary (injectable for tests)
      sig { params(executor: Executor).void }
      def initialize(executor: Executor.new)
        @executor = executor
      end

      # Clone full_name into destination, creating parent directories first
      # (the canonical layout's host/org levels may not exist yet).
      #
      # @param full_name [String] "owner/repo"
      # @param destination [Pathname] the target checkout directory
      # @return [void]
      # @raise [CloneFailedError] when the clone exits non-zero
      sig { params(full_name: String, destination: Pathname).void }
      def clone(full_name, destination)
        FileUtils.mkdir_p(destination.dirname)
        return if @executor.system("gh", "repo", "clone", full_name, destination.to_s)

        raise CloneFailedError, "gh repo clone #{full_name} failed — is gh authenticated? (gh auth login)"
      end
    end
  end
end
