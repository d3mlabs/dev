# typed: strict
# frozen_string_literal: true

module Dev
  # Declared CPU/memory the build container expects from the Docker VM.
  #
  # These are *requirements*, not grants. Docker Desktop runs a single shared
  # Linux VM whose size is a host-wide setting, so a project cannot give itself
  # more cores or memory than the VM has. dev uses these values only for a
  # preflight check: when the VM is smaller than declared it warns loudly with
  # remediation, so an under-provisioned host surfaces immediately instead of
  # silently serializing the build (UBT sizes its parallelism off available
  # memory, ~1.5 GiB per compile action).
  #
  # We deliberately do NOT translate these into `docker run --memory` caps: the
  # declared memory is a floor the build needs, and capping a container at its
  # requirement leaves no headroom and invites the OOM killer.
  #
  # dev.yml:
  #   build:
  #     container:
  #       resources:
  #         cpus: 16
  #         memory_gb: 24
  class ContainerResources
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    attr_reader :cpus

    sig { returns(T.nilable(Integer)) }
    attr_reader :memory_gb

    sig { params(cpus: T.nilable(Integer), memory_gb: T.nilable(Integer)).void }
    def initialize(cpus: nil, memory_gb: nil)
      @cpus = T.let(cpus, T.nilable(Integer))
      @memory_gb = T.let(memory_gb, T.nilable(Integer))
    end

    sig { returns(T::Boolean) }
    def empty?
      @cpus.nil? && @memory_gb.nil?
    end

    # Human-readable shortfalls when the host VM is smaller than declared.
    # Pure by design so the preflight logic is testable without Docker.
    #
    # @param available_cpus [Integer] cores the Docker VM exposes
    # @param available_memory_gb [Integer] GiB the Docker VM exposes
    # @return [Array<String>] one message per dimension that falls short (empty if ok)
    sig { params(available_cpus: Integer, available_memory_gb: Integer).returns(T::Array[String]) }
    def shortfalls(available_cpus:, available_memory_gb:)
      messages = []

      required_cpus = @cpus
      if required_cpus && available_cpus < required_cpus
        messages << "CPUs: #{available_cpus} available < #{required_cpus} declared"
      end

      required_memory_gb = @memory_gb
      if required_memory_gb && available_memory_gb < required_memory_gb
        messages << "Memory: #{available_memory_gb} GiB available < #{required_memory_gb} GiB declared"
      end

      messages
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ContainerResources)

      @cpus == other.cpus && @memory_gb == other.memory_gb
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      [@cpus, @memory_gb].hash
    end
  end
end
