# typed: strict
# frozen_string_literal: true

require "dev/runner_role"
require_relative "value_equality"

module Dev
  # Value object for one enrollment's identity, resolved by `dev runner
  # register` from its flags and derivations (never a file — the dev.yml
  # `runner:` block is retired): the **role** the slot plays (RunnerRole —
  # the labels config.sh advertises and the runner group the registration
  # joins both derive from it), optional dir/name/version overrides (see
  # Dev::RunnerSetup for their defaults: ~/actions-runner-<role suffix>,
  # the hostname, and the pinned runner version), and whether config.sh
  # may `--replace` a registration GitHub already holds under the name
  # (only this family's own).
  class RunnerSetupConfig
    extend T::Sig
    include Dev::ValueEquality::Derived

    sig { returns(RunnerRole) }
    attr_reader :role

    sig { returns(T.nilable(String)) }
    attr_reader :dir

    sig { returns(T.nilable(String)) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :version

    # Whether config.sh takes over a registration already held under this
    # name (`--replace`). GitHub refuses a duplicate runner name at a scope;
    # `--replace` turns that refusal into a takeover, so it is only ever
    # true for a name whose registration is this family's own — register
    # decides, having looked the name up. False enrolls plainly:
    # a name nothing holds needs no replacing, and one another family holds
    # is refused upstream rather than stolen here.
    sig { returns(T::Boolean) }
    attr_reader :replace

    sig do
      params(
        role: RunnerRole,
        dir: T.nilable(String),
        name: T.nilable(String),
        version: T.nilable(String),
        replace: T::Boolean,
      ).void
    end
    def initialize(role:, dir: nil, name: nil, version: nil, replace: false)
      @role = role
      @dir = dir
      @name = name
      @version = version
      @replace = replace
    end

    # The labels config.sh advertises: the role's, comma-separated.
    #
    # @return [String]
    sig { returns(String) }
    def labels
      @role.labels.join(",")
    end

    # The runner group config.sh names (`--runnergroup`): the role's; nil
    # lands the registration in GitHub's Default.
    sig { returns(T.nilable(String)) }
    def group
      @role.group&.name
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@role, @dir, @name, @version, @replace]
    end
  end
end
