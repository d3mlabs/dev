# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for one enrollment's identity, resolved by `dev runner
  # register` from its flags and derivations (never a file — the dev.yml
  # `runner:` block is retired): the comma-separated labels config.sh
  # expects, plus optional dir/name/version overrides (see Dev::RunnerSetup
  # for their defaults: ~/actions-runner-<first label>, the hostname, and
  # the pinned runner version).
  class RunnerSetupConfig
    extend T::Sig

    sig { returns(String) }
    attr_reader :labels

    sig { returns(T.nilable(String)) }
    attr_reader :dir

    sig { returns(T.nilable(String)) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :version

    sig do
      params(
        labels: String,
        dir: T.nilable(String),
        name: T.nilable(String),
        version: T.nilable(String),
      ).void
    end
    def initialize(labels:, dir: nil, name: nil, version: nil)
      @labels = labels
      @dir = dir
      @name = name
      @version = version
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(RunnerSetupConfig)

      @labels == other.labels && @dir == other.dir &&
        @name == other.name && @version == other.version
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@labels, @dir, @name, @version].hash
    end
  end
end
