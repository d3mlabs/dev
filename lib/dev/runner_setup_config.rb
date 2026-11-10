# typed: strict
# frozen_string_literal: true

require_relative "value_equality"

module Dev
  # Value object for one enrollment's identity, resolved by `dev runner
  # register` from its flags and derivations (never a file — the dev.yml
  # `runner:` block is retired): the comma-separated labels config.sh
  # expects, plus optional dir/name/version overrides (see Dev::RunnerSetup
  # for their defaults: ~/actions-runner-<first label>, the hostname, and
  # the pinned runner version) and, at an org scope, the runner group the
  # registration joins (config.sh's `--runnergroup`; unnamed = Default).
  class RunnerSetupConfig
    extend T::Sig
    include Dev::ValueEquality::Derived

    sig { returns(String) }
    attr_reader :labels

    sig { returns(T.nilable(String)) }
    attr_reader :dir

    sig { returns(T.nilable(String)) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :version

    sig { returns(T.nilable(String)) }
    attr_reader :group

    sig do
      params(
        labels: String,
        dir: T.nilable(String),
        name: T.nilable(String),
        version: T.nilable(String),
        group: T.nilable(String),
      ).void
    end
    def initialize(labels:, dir: nil, name: nil, version: nil, group: nil)
      @labels = labels
      @dir = dir
      @name = name
      @version = version
      @group = group
    end

    # The first label, sanitized for a dir name: what the default install
    # dir (`~/actions-runner-<suffix>`) and, when a scope already has a
    # family under the bare hostname, the runner name (`<hostname>-<suffix>`)
    # are derived from (dev#557) — one derivation, so a family's dirs and
    # names say the same thing.
    #
    # @return [String]
    sig { returns(String) }
    def dir_suffix
      first = @labels.split(",").first.to_s
      sanitized = first.gsub(/[^A-Za-z0-9_.-]/, "-")
      sanitized.empty? ? "default" : sanitized
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [@labels, @dir, @name, @version, @group]
    end
  end
end
