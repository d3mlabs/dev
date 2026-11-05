# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Lifecycle
    # The git CLI boundary of the sync step: every git call the snapshot
    # commit, the snapshot branches and the prune make goes through one
    # method over one checkout, capturing what git prints so a failure
    # carries git's own words. Tests run it against real repositories in
    # temporary directories; nothing here is worth mocking.
    #
    # Never prompts: a push whose credential is missing fails with git's
    # message instead of hanging a lifecycle verb on a hidden prompt.
    class Git
      extend T::Sig

      # git exited nonzero; the message carries the argv and git's stderr.
      class CommandFailedError < RuntimeError; end

      # No git on PATH.
      class GitMissingError < RuntimeError; end

      Argv = T.type_alias { T::Array[String] }
      NO_PROMPT_ENV = T.let({ "GIT_TERMINAL_PROMPT" => "0" }.freeze, T::Hash[String, String])

      # @return [Pathname] the checkout every call runs in
      sig { returns(Pathname) }
      attr_reader :root

      # @param root [Pathname] the checkout (passed as `git -C`)
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
      end

      # Run one git command and return what it printed.
      #
      # @param argv [Array<String>] git's arguments, after `-C <root>`
      # @param env [Hash{String => String}] variables added to dev's own
      # @return [String] stdout, as printed (callers strip)
      # @raise [CommandFailedError]
      # @raise [GitMissingError]
      sig { params(argv: Argv, env: T::Hash[String, String]).returns(String) }
      def capture(argv, env: {})
        out, err, status = T.unsafe(Open3).capture3(NO_PROMPT_ENV.merge(env), "git", "-C", @root.to_s, *argv)
        raise CommandFailedError, "git #{argv.join(" ")} failed in #{@root}: #{err.strip}" unless status.success?

        out
      rescue Errno::ENOENT
        raise GitMissingError, "git not found on PATH"
      end

      # Whether a git command succeeds, for the questions git answers with
      # its exit code (`rev-parse --verify`).
      #
      # @param argv [Array<String>]
      # @return [Boolean]
      # @raise [GitMissingError]
      sig { params(argv: Argv).returns(T::Boolean) }
      def succeeds?(argv)
        _out, _err, status = T.unsafe(Open3).capture3(NO_PROMPT_ENV, "git", "-C", @root.to_s, *argv)
        status.success?
      rescue Errno::ENOENT
        raise GitMissingError, "git not found on PATH"
      end
    end
  end
end
