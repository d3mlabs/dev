# typed: strict
# frozen_string_literal: true

require_relative "git"
require_relative "snapshot"
require_relative "../actions_job_context"

module Dev
  module Lifecycle
    # The checkout an Actions job runs in, read as a snapshot the forge
    # already serves. A job is given a commit at a ref — `GITHUB_SHA` at
    # `GITHUB_REF`, `refs/pull/<n>/merge` for a pull request, a branch for
    # a push — and `actions/checkout` puts exactly that commit at HEAD. As
    # long as the tree is still that commit (no tracked change, no
    # untracked file; ignored files do not count, as they never enter a
    # snapshot), a container can fetch the job's ref and needs no branch
    # pushed for it — which a job's token, `contents: read` by default,
    # could not push anyway.
    #
    # Outside a job, or when any of those facts does not hold, there is no
    # checkout snapshot and the sync step commits and pushes as it does
    # anywhere; `reason` says which fact failed, for the push error to
    # carry.
    class JobCheckout
      extend T::Sig

      SHA = "GITHUB_SHA"
      REF = "GITHUB_REF"

      # @param git [Git] over the checkout
      # @param env [Hash{String => String}] the environment to read, the
      #   process's own by default
      sig { params(git: Git, env: T::Hash[String, String]).void }
      def initialize(git:, env: ENV.to_h)
        @git = git
        @env = env
        @reason = T.let(nil, T.nilable(String))
      end

      # @return [Snapshot, nil] the job's checkout as the forge has it; nil
      #   outside a job, or when the tree is not the job's commit as given
      sig { returns(T.nilable(Snapshot)) }
      def snapshot
        return unless ActionsJobContext.inside?(@env)

        sha = @env[SHA].to_s
        ref = @env[REF].to_s
        return unless present!(sha, SHA) && present!(ref, REF)
        return unless at_head!(sha)
        return unless clean!

        Snapshot.checked_out(sha:, ref:)
      end

      # @return [String, nil] why the last `snapshot` was nil inside a job;
      #   nil outside a job or when it was not
      sig { returns(T.nilable(String)) }
      attr_reader :reason

      private

      # @param value [String]
      # @param name [String] the variable's name
      # @return [Boolean]
      sig { params(value: String, name: String).returns(T::Boolean) }
      def present!(value, name)
        return true unless value.empty?

        @reason = "the job carries no #{name}"
        false
      end

      # @param sha [String] the job's commit
      # @return [Boolean] whether HEAD is it
      sig { params(sha: String).returns(T::Boolean) }
      def at_head!(sha)
        head = @git.succeeds?(["rev-parse", "--verify", "--quiet", "HEAD"]) ? @git.capture(["rev-parse", "HEAD"]).strip : nil
        return true if head == sha

        @reason = "HEAD is #{head || "unborn"}, not the job's #{sha}"
        false
      end

      # @return [Boolean] whether the tree is HEAD's: nothing tracked
      #   changed, nothing untracked (ignored files aside)
      sig { returns(T::Boolean) }
      def clean!
        status = @git.capture(["status", "--porcelain"]).strip
        return true if status.empty?

        @reason = "the checkout has changes since the job's commit:\n#{status}"
        false
      end
    end
  end
end
