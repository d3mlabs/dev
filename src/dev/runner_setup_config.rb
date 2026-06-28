# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for the `runner` block in dev.yml.
  #
  # When present, `dev runner-setup` registers the current host as the repo's
  # self-hosted GitHub Actions runner with these labels. dev owns the install
  # logic (Dev::RunnerSetup), so every repo declares only its runner identity
  # here instead of vendoring a bespoke setup script.
  #
  # dev.yml example:
  #   runner:
  #     labels: ue-engine
  #     dir: "~/actions-runner-ue"   # optional; defaults to ~/actions-runner-<label>
  #     name: my-box                 # optional; defaults to the hostname
  #     version: "2.335.1"           # optional; defaults to RunnerSetup::DEFAULT_VERSION
  #
  # labels may be a single string ("ue-engine") or a YAML list ([ue-engine, x64]);
  # both normalize to the comma-separated form `config.sh --labels` expects. dir,
  # name, and version are optional overrides (see Dev::RunnerSetup for defaults).
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
      @labels = T.let(labels, String)
      @dir = T.let(dir, T.nilable(String))
      @name = T.let(name, T.nilable(String))
      @version = T.let(version, T.nilable(String))
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
