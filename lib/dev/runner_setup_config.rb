# typed: strict
# frozen_string_literal: true

require_relative "value_equality"

module Dev
  # Value object for one enrollment's identity, resolved by `dev runner
  # register` from its flags and derivations (never a file — the dev.yml
  # `runner:` block is retired): the comma-separated labels config.sh
  # expects, plus optional dir/name/version overrides (see Dev::RunnerSetup
  # for their defaults: ~/actions-runner-<first label>, the hostname, and
  # the pinned runner version), at an org scope the runner group the
  # registration joins (config.sh's `--runnergroup`; unnamed = Default),
  # and whether config.sh may `--replace` a registration GitHub already
  # holds under the name (register's rule, dev#565: only this family's own).
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

    # Whether config.sh takes over a registration already held under this
    # name (`--replace`). GitHub refuses a duplicate runner name at a scope;
    # `--replace` turns that refusal into a takeover, so it is only ever
    # true for a name whose registration is this family's own — register
    # decides, having looked the name up (dev#565). False enrolls plainly:
    # a name nothing holds needs no replacing, and one another family holds
    # is refused upstream rather than stolen here.
    sig { returns(T::Boolean) }
    attr_reader :replace

    sig do
      params(
        labels: String,
        dir: T.nilable(String),
        name: T.nilable(String),
        version: T.nilable(String),
        group: T.nilable(String),
        replace: T::Boolean,
      ).void
    end
    def initialize(labels:, dir: nil, name: nil, version: nil, group: nil, replace: false)
      @labels = labels
      @dir = dir
      @name = name
      @version = version
      @group = group
      @replace = replace
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
      [@labels, @dir, @name, @version, @group, @replace]
    end
  end
end
