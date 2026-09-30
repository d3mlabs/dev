# typed: strict
# frozen_string_literal: true

require "dev/build_container_config"

module Dev
  # What a container engine actually has: whole cpus and GiB, as its daemon
  # reports them. The counterpart of BuildContainerConfig::Resources — the
  # repo's *minimum* — so the two compare field by field: a hint field left
  # nil demands nothing.
  class EngineResources
    extend T::Sig

    GIB = 1_073_741_824 # 1024**3

    sig { returns(Integer) }
    attr_reader :cpus

    sig { returns(Integer) }
    attr_reader :memory_gib

    # @param cpus [Integer]
    # @param memory_gib [Integer]
    sig { params(cpus: Integer, memory_gib: Integer).void }
    def initialize(cpus:, memory_gib:)
      @cpus = cpus
      @memory_gib = memory_gib
    end

    class << self
      extend T::Sig

      # Build from a daemon's raw numbers. MemTotal comes back under the VM's
      # nominal size (a 24 GiB colima VM reports ~23.4: the guest kernel keeps
      # some), so it is rounded *up* to the GiB the VM was given — anything
      # else would read a correctly sized VM as undersized forever.
      #
      # @param cpus [Integer]
      # @param memory_bytes [Integer]
      # @return [EngineResources]
      sig { params(cpus: Integer, memory_bytes: Integer).returns(EngineResources) }
      def from_bytes(cpus:, memory_bytes:)
        new(cpus: cpus, memory_gib: (memory_bytes.to_f / GIB).ceil)
      end
    end

    # Whether this engine meets a repo's hint. Each declared field must be
    # met; a nil field, or a nil hint, requires nothing.
    #
    # @param hint [BuildContainerConfig::Resources, nil] the repo's minimum
    # @return [Boolean]
    sig { params(hint: T.nilable(BuildContainerConfig::Resources)).returns(T::Boolean) }
    def satisfies?(hint)
      return true if hint.nil?

      cpus_ok = hint.cpus.nil? || @cpus >= T.must(hint.cpus)
      memory_ok = hint.memory_gib.nil? || @memory_gib >= T.must(hint.memory_gib)
      cpus_ok && memory_ok
    end

    sig { returns(String) }
    def to_s
      "#{@cpus} cpus / #{@memory_gib} GiB"
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(EngineResources) && @cpus == other.cpus && @memory_gib == other.memory_gib
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@cpus, @memory_gib].hash
    end
  end
end
