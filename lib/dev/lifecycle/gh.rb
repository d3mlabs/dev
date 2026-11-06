# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Lifecycle
    # The gh CLI boundary of the lifecycle's forge writes and reads — the
    # deployment ledger (GithubDeployments) today; the release's assets
    # (dev#424) next. Every call goes through one method over one
    # checkout, so gh resolves the repo the way it does for the operator
    # (`gh repo view` reads the checkout's `origin`) and the auth it holds
    # — the operator's login, or a workflow's GITHUB_TOKEN through GH_TOKEN
    # — is the one credential dev carries to every GitHub surface (GhAuth).
    # Payloads go through stdin so a body never hits argv.
    #
    # The one place gh is spawned by the lifecycle, and so the one thing a
    # test of the ledger hands a fake for: gh is a true boundary, the
    # forge behind it is not reproducible in a temp dir.
    class Gh
      extend T::Sig

      # gh exited nonzero; the message carries the argv and gh's stderr.
      class CommandFailedError < RuntimeError; end

      # No gh on PATH.
      class GhMissingError < RuntimeError; end

      Argv = T.type_alias { T::Array[String] }

      # @return [Pathname] the checkout every call runs in
      sig { returns(Pathname) }
      attr_reader :root

      # @param root [Pathname] the checkout gh resolves the repo from
      sig { params(root: Pathname).void }
      def initialize(root:)
        @root = root
      end

      # Run one gh command and return what it printed.
      #
      # @param argv [Array<String>] gh's arguments
      # @param stdin [String, nil] a body piped to gh's stdin
      # @return [String] stdout, as printed
      # @raise [CommandFailedError]
      # @raise [GhMissingError]
      sig { params(argv: Argv, stdin: T.nilable(String)).returns(String) }
      def capture(argv, stdin: nil)
        out, err, status = T.unsafe(Open3).capture3("gh", *argv, stdin_data: stdin, chdir: @root.to_s)
        raise CommandFailedError, "gh #{argv.join(" ")} failed in #{@root}: #{err.strip}" unless status.success?

        out
      rescue Errno::ENOENT
        raise GhMissingError, "gh not found on PATH"
      end
    end
  end
end
