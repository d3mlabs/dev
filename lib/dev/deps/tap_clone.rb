# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/lifecycle/git"
require_relative "formula_file"
require_relative "tap"

module Dev
  module Deps
    # Dev's own clone of a Homebrew tap, for writing to it: where the brew
    # publisher rewrites formulas, commits and pushes. It is the publisher's
    # scratch, a directory nobody edits between publishes, which is what
    # makes `sync!` safe to reset to the tap's tip rather than merge: the
    # clone is exactly `origin`'s default branch when a formula is
    # rewritten, so the push that follows is a fast-forward unless someone
    # pushed in the meantime (then git refuses, and the retry syncs again).
    # fast-forwarded first; a clone dev owns needs none of that.
    #
    # Reads and writes go through Lifecycle::Git over the clone, so a
    # failure carries git's words; the commit is the operator's own (their
    # identity, as the release commit is).
    class TapClone
      extend T::Sig

      # The tap carries no formula of the name asked for.
      class FormulaMissingError < RuntimeError; end

      FORMULA_DIR = "Formula"
      REMOTE = "origin"
      # The clone's record of the remote's default branch (`git clone` sets
      # it; `remote set-head -a` refreshes it).
      REMOTE_HEAD = "origin/HEAD"

      # @return [Tap]
      sig { returns(Tap) }
      attr_reader :tap

      # @return [Pathname] where the clone lives
      sig { returns(Pathname) }
      attr_reader :dir

      # @param tap [Tap] the tap; its url when it has one, else its GitHub
      #   repository under brew's naming convention
      # @param dir [Pathname] the clone's directory; created by `sync!`
      sig { params(tap: Tap, dir: Pathname).void }
      def initialize(tap:, dir:)
        @tap = tap
        @dir = dir
        @git = T.let(Lifecycle::Git.new(root: dir), Lifecycle::Git)
      end

      # The tap's clone url: the declared one, else `github.com/<user>/homebrew-<repo>`.
      #
      # @return [String]
      sig { returns(String) }
      def remote_url
        url = @tap.url
        return url.to_s if url

        user, repo = @tap.name.split("/", 2)
        "https://github.com/#{user}/homebrew-#{repo}.git"
      end

      # Bring the clone to the tap's current tip: cloned when absent, else
      # fetched and reset hard to the remote's default branch.
      #
      # @return [void]
      # @raise [Lifecycle::Git::CommandFailedError] the remote is unreachable or refuses
      sig { void }
      def sync!
        if (@dir / ".git").exist?
          @git.capture(["fetch", "-q", REMOTE])
          @git.capture(["remote", "set-head", REMOTE, "-a"])
          # A rewrite whose commit or push failed is still in the tree or on
          # the branch; both go, and the retry rewrites from the tip.
          @git.capture(["reset", "-q", "--hard"])
          @git.capture(["checkout", "-q", "-B", branch, "#{REMOTE}/#{branch}"])
        else
          @dir.parent.mkpath
          Lifecycle::Git.new(root: @dir.parent).capture(["clone", "-q", remote_url, @dir.basename.to_s])
        end
      end

      # The remote's default branch — what the clone tracks and the push publishes.
      #
      # @return [String]
      # @raise [Lifecycle::Git::CommandFailedError] before the first `sync!`
      sig { returns(String) }
      def branch
        @git.capture(["rev-parse", "--abbrev-ref", REMOTE_HEAD]).strip.delete_prefix("#{REMOTE}/")
      end

      # A formula the tap carries.
      #
      # @param name [String] the formula's name
      # @return [FormulaFile]
      # @raise [FormulaMissingError]
      sig { params(name: String).returns(FormulaFile) }
      def formula(name)
        path = @dir / FORMULA_DIR / "#{name}#{FormulaFile::EXTENSION}"
        unless path.file?
          raise FormulaMissingError,
            "#{@tap.name} carries no #{FORMULA_DIR}/#{name}#{FormulaFile::EXTENSION} — dev updates a formula's url and sha256, it does not " \
              "author one; add the formula to the tap first"
        end

        FormulaFile.new(path:)
      end

      # Commit the given files on the default branch.
      #
      # @param message [String]
      # @param files [Array<FormulaFile>] what changed
      # @return [void]
      # @raise [Lifecycle::Git::CommandFailedError]
      sig { params(message: String, files: T::Array[FormulaFile]).void }
      def commit!(message:, files:)
        @git.capture(["add", "--", *files.map { |file| file.path.relative_path_from(@dir).to_s }])
        @git.capture(["commit", "-q", "-m", message])
      end

      # Publish the default branch to the remote.
      #
      # @return [void]
      # @raise [Lifecycle::Git::CommandFailedError] the remote refuses (not a
      #   fast-forward: the tap moved since `sync!`; retry)
      sig { void }
      def push!
        @git.capture(["push", "-q", REMOTE, "HEAD:refs/heads/#{branch}"])
      end

      # The commit the clone is at.
      #
      # @return [String] the full sha
      # @raise [Lifecycle::Git::CommandFailedError]
      sig { returns(String) }
      def head
        @git.capture(["rev-parse", "HEAD"]).strip
      end
    end
  end
end
