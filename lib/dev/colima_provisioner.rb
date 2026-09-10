# typed: strict
# frozen_string_literal: true

require "open3"

module Dev
  # Per-user provisioning for the colima engine: idempotently ensure the
  # invoking user's own colima VM is running. This is what gives a no-GUI
  # user (the agent account) a docker daemon of its own — Docker Desktop
  # cannot serve it. The VM is vz-virtualized with Rosetta so amd64 build
  # images (e.g. the linux cross-compile image) run on Apple silicon.
  #
  # Sizing comes from the repo's build.container.resources hint when given
  # (a UE compile wants more than the shipped defaults); colima applies
  # --cpu/--memory only at VM creation, so the first provision decides.
  class ColimaProvisioner
    extend T::Sig

    # `colima start` exited nonzero — the VM could not be brought up.
    class StartFailedError < RuntimeError; end

    # Shipped VM sizing when the repo declares no resources hint.
    DEFAULT_CPUS = 4
    DEFAULT_MEMORY_GIB = 8

    # Runs colima commands. Same split as HostService::BrewExecutor: `run`
    # streams output to the terminal (a VM start the user should see),
    # `quiet?` only answers success (the status probe).
    class Executor
      extend T::Sig

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def run(*cmd)
        !!T.unsafe(Kernel).system(*cmd)
      end

      # @param cmd [Array<String>] argv, never a shell string
      # @return [Boolean]
      sig { params(cmd: String).returns(T::Boolean) }
      def quiet?(*cmd)
        _out, _err, status = T.unsafe(Open3).capture3(*cmd)
        status.success?
      rescue SystemCallError
        false
      end
    end

    # @param executor [#run, #quiet?] colima invocation seam, injectable so
    #   tests never spawn a VM
    sig { params(executor: T.untyped).void }
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # Ensure the user's colima VM runs, starting it (sized) when it does not.
    # Idempotent: `colima status` succeeding means nothing to do.
    #
    # @param cpus [Integer, nil] VM CPU count (repo resources hint), or the default
    # @param memory_gib [Integer, nil] VM memory in GiB, or the default
    # @return [void]
    # @raise [StartFailedError] when the VM cannot be brought up
    sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).void }
    def provision!(cpus: nil, memory_gib: nil)
      return if running?

      args = [
        "colima", "start",
        "--cpu", (cpus || DEFAULT_CPUS).to_s,
        "--memory", (memory_gib || DEFAULT_MEMORY_GIB).to_s,
        "--vm-type", "vz", "--vz-rosetta"
      ]
      return if T.unsafe(@executor).run(*args)

      raise StartFailedError, "colima start failed — the agent's engine VM could not be brought up."
    end

    private

    # @return [Boolean] whether the user's colima VM is already up
    sig { returns(T::Boolean) }
    def running?
      @executor.quiet?("colima", "status")
    end
  end
end
