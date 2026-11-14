# typed: strict
# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "build_id"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The branch a working-tree snapshot is pushed to for a remote
    # dispatch: `dev/build/<runner>/<id>` under `refs/heads/`, since
    # `workflow_dispatch` accepts only a branch or a tag. The namespace is
    # dev's own, which is what lets `dev cache gc` prune it by age.
    #
    # The id is `<utc instant>-<nonce>`, so a branch carries its own
    # creation time and the prune reads ages from `git ls-remote` alone.
    class SnapshotBranch
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A branch name under the namespace that the sync step did not mint
      # (a hand-made `dev/build/foo`).
      class MalformedSnapshotBranchError < ArgumentError; end

      # A runner label that cannot be one path segment of a git ref.
      class InvalidRunnerLabelError < ArgumentError; end

      NAMESPACE = "dev/build"
      REF_PREFIX = "refs/heads/"
      # What `git ls-remote` is asked for: every branch under the namespace.
      REFSPEC_GLOB = T.let("#{REF_PREFIX}#{NAMESPACE}/*".freeze, String)
      NONCE_BYTES = 3
      # One segment of a ref name, in the subset of git's rules a runner
      # label meets: no `/`, no spaces, none of git's reserved characters,
      # not starting with `.`, not ending in `.lock`.
      RUNNER_PATTERN = /\A(?!\.)[A-Za-z0-9._-]+(?<!\.lock)\z/
      NAME_PATTERN = %r{
        \A#{NAMESPACE}/(?<runner>[^/]+)/(?<instant>#{BuildId::INSTANT_PATTERN})-(?<nonce>\h{#{NONCE_BYTES * 2}})\z
      }x

      # @return [String] the runner label the snapshot was dispatched to
      sig { returns(String) }
      attr_reader :runner

      # @return [Time] when the branch was minted, UTC, to the second
      sig { returns(Time) }
      attr_reader :created_at

      # @return [String] what keeps two snapshots minted in one second apart
      sig { returns(String) }
      attr_reader :nonce

      class << self
        extend T::Sig

        # A fresh branch for a dispatch to a runner.
        #
        # @param runner [String] the runner label
        # @param now [Time] (injectable for tests)
        # @param nonce [String] (injectable for tests)
        # @return [SnapshotBranch]
        # @raise [InvalidRunnerLabelError]
        sig { params(runner: String, now: Time, nonce: String).returns(SnapshotBranch) }
        def mint(runner:, now: Time.now, nonce: SecureRandom.hex(NONCE_BYTES))
          new(runner:, created_at: now, nonce:)
        end

        # Read a branch back from its name — as `ls-remote` lists it
        # (`refs/heads/dev/build/…`) or short (`dev/build/…`).
        #
        # @param name [String]
        # @return [SnapshotBranch]
        # @raise [MalformedSnapshotBranchError]
        sig { params(name: String).returns(SnapshotBranch) }
        def parse(name)
          match = NAME_PATTERN.match(name.delete_prefix(REF_PREFIX))
          unless match
            raise MalformedSnapshotBranchError,
              "#{name.inspect} is not a snapshot branch (#{NAMESPACE}/<runner>/<utc instant>-<nonce>)"
          end

          new(
            runner: T.must(match[:runner]),
            created_at: Time.strptime("#{match[:instant]} UTC", "#{BuildId::INSTANT_FORMAT} %Z"),
            nonce: T.must(match[:nonce]),
          )
        end
      end

      # @param runner [String]
      # @param created_at [Time]
      # @param nonce [String]
      # @raise [InvalidRunnerLabelError]
      # @raise [MalformedSnapshotBranchError] on a nonce outside the grammar
      sig { params(runner: String, created_at: Time, nonce: String).void }
      def initialize(runner:, created_at:, nonce:)
        unless RUNNER_PATTERN.match?(runner)
          raise InvalidRunnerLabelError,
            "runner label #{runner.inspect} cannot name a branch segment (letters, digits, `.`, `_`, `-`; " \
              "not starting with `.`, not ending in `.lock`)"
        end
        unless /\A\h{#{NONCE_BYTES * 2}}\z/.match?(nonce)
          raise MalformedSnapshotBranchError, "nonce #{nonce.inspect} is not #{NONCE_BYTES * 2} hex digits"
        end

        @runner = runner
        # Truncated to the second: the name carries no finer grain, so a
        # minted branch and its parse are equal.
        @created_at = T.let(Time.at(created_at.to_i).utc, Time)
        @nonce = nonce
        freeze
      end

      # @return [String] the short branch name (`dev/build/<runner>/<id>`)
      sig { returns(String) }
      def name
        "#{NAMESPACE}/#{@runner}/#{@created_at.strftime(BuildId::INSTANT_FORMAT)}-#{@nonce}"
      end

      # @return [String] the full ref (`refs/heads/dev/build/<runner>/<id>`)
      sig { returns(String) }
      def ref
        "#{REF_PREFIX}#{name}"
      end

      # Whether the branch was minted more than `max_age` ago.
      #
      # @param max_age [Integer] seconds
      # @param now [Time]
      # @return [Boolean]
      sig { params(max_age: Integer, now: Time).returns(T::Boolean) }
      def older_than?(max_age, now:)
        now - @created_at > max_age
      end

      sig { returns(String) }
      def to_s
        name
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name]
      end
    end
  end
end
