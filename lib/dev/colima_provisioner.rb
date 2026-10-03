# typed: strict
# frozen_string_literal: true

require "json"

require "dev/process_executor"

module Dev
  # Per-user provisioning for the colima engine: idempotently ensure the
  # invoking user's own colima VM is running *and big enough*. colima is the
  # one macOS engine: it serves a human's `dev up` and a no-GUI agent
  # account alike, and dev owns its whole lifecycle. The VM is
  # vz-virtualized with Rosetta so amd64 build images (e.g. the linux
  # cross-compile image) run on Apple silicon.
  #
  # Sizing: the repo's build.container.resources hint is a per-project
  # *minimum* against one VM every project on the machine shares. colima
  # applies --cpu/--memory whenever a VM starts from stopped (the disk, and
  # with it images and warm containers, survives), so resizing is cheap and
  # non-destructive — the only question is who is using the VM right now:
  #
  # - no VM: create it at the hint (defaults for undeclared fields).
  # - stopped: start at exactly the hint. Nobody is using a stopped VM, so it
  #   may shrink; an undeclared field keeps the VM's current value (no
  #   requirement is not a request to shrink). This is the reclaim path:
  #   `dev down` the big project, `dev up` the small one.
  # - running and at least the hint: nothing to do.
  # - running, undersized, idle (no containers): stop and restart at the
  #   ratchet — max(current, hint) per field — never shrinking under a
  #   project whose containers are merely stopped-but-warm.
  # - running, undersized, busy: refuse (EngineBusyError) naming the
  #   containers in the way. Stopping the VM would kill someone's build.
  class ColimaProvisioner
    extend T::Sig

    # `colima start` exited nonzero — the VM could not be brought up.
    class StartFailedError < RuntimeError; end

    # `colima stop` exited nonzero mid-resize — the VM is left as it was.
    class StopFailedError < RuntimeError; end

    # The VM is undersized for this project but another project's containers
    # are running in it; resizing means stopping the VM under them.
    class EngineBusyError < RuntimeError; end

    # Shipped VM sizing when the repo declares no resources hint.
    DEFAULT_CPUS = 4
    DEFAULT_MEMORY_GIB = 8

    # The colima profile dev owns (colima's own default).
    PROFILE = "default"
    GIB = 1_073_741_824 # 1024**3

    # Runs colima commands — the shared process boundary (see ProcessExecutor).
    Executor = ProcessExecutor

    # What `colima list` says about the VM.
    class Vm < T::Struct
      const :running, T::Boolean
      const :cpus, Integer
      const :memory_gib, Integer
    end

    # @param executor [#run, #quiet?, #capture] colima invocation seam,
    #   injectable so tests never spawn a VM
    sig { params(executor: T.untyped).void }
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # Ensure the user's colima VM runs at (at least) the requested size. See
    # the class doc for the decision table.
    #
    # @param cpus [Integer, nil] VM CPU minimum (repo resources hint)
    # @param memory_gib [Integer, nil] VM memory minimum in GiB
    # @return [void]
    # @raise [StartFailedError] when the VM cannot be brought up
    # @raise [StopFailedError] when a resize cannot stop the VM
    # @raise [EngineBusyError] when a resize is needed but containers are running
    sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).void }
    def provision!(cpus: nil, memory_gib: nil)
      vm = inspect_vm
      return start!(cpus || DEFAULT_CPUS, memory_gib || DEFAULT_MEMORY_GIB) if vm.nil?
      return start!(cpus || vm.cpus, memory_gib || vm.memory_gib) unless vm.running

      target_cpus = [vm.cpus, cpus || 0].max
      target_memory = [vm.memory_gib, memory_gib || 0].max
      return if target_cpus == vm.cpus && target_memory == vm.memory_gib

      busy = running_containers
      unless busy.empty?
        raise EngineBusyError,
          "the colima VM has #{vm.cpus} cpus / #{vm.memory_gib} GiB; this project needs " \
          "#{cpus || vm.cpus} cpus / #{memory_gib || vm.memory_gib} GiB, and resizing means stopping " \
          "the VM — but containers are running in it:\n  #{busy.join("\n  ")}\n" \
          "Bring those projects down first (`dev reset-container` there, or `docker stop`), " \
          "or stop the VM yourself with `colima stop` and re-run `dev up`."
      end

      raise StopFailedError, "colima stop failed — the VM was left running at its current size." unless
        T.unsafe(@executor).run("colima", "stop")

      start!(target_cpus, target_memory)
    end

    # The VM as `colima list` reports it — `dev engine status`'s colima
    # facts.
    #
    # @return [Vm, nil] nil when the profile does not exist (or colima is absent)
    sig { returns(T.nilable(Vm)) }
    def status
      inspect_vm
    end

    # Stop the VM — the only way colima reclaims its RAM (no ballooning).
    # Whatever is running inside goes down with it: whether that is
    # acceptable is the caller's decision (`dev engine down` stops dev's own
    # containers and asks about the user's first), not this primitive's. A
    # stopped or absent VM is already where `stop!` leaves things.
    #
    # @return [void]
    # @raise [StopFailedError] when `colima stop` exits nonzero
    sig { void }
    def stop!
      vm = inspect_vm
      return if vm.nil? || !vm.running
      return if T.unsafe(@executor).run("colima", "stop")

      raise StopFailedError, "colima stop failed — the VM was left running."
    end

    private

    # @param cpus [Integer]
    # @param memory_gib [Integer]
    # @return [void]
    # @raise [StartFailedError]
    sig { params(cpus: Integer, memory_gib: Integer).void }
    def start!(cpus, memory_gib)
      args = [
        "colima", "start",
        "--cpu", cpus.to_s,
        "--memory", memory_gib.to_s,
        "--vm-type", "vz", "--vz-rosetta"
      ]
      return if T.unsafe(@executor).run(*args)

      raise StartFailedError, "colima start failed — the container engine VM could not be brought up."
    end

    # The dev profile as `colima list -j` reports it: one JSON object per
    # line, one per profile.
    #
    # @return [Vm, nil] nil when the profile does not exist (or colima is absent)
    sig { returns(T.nilable(Vm)) }
    def inspect_vm
      out = T.unsafe(@executor).capture("colima", "list", "-j")
      out.each_line do |line|
        next if line.strip.empty?

        record = JSON.parse(line)
        next unless record["name"] == PROFILE

        return Vm.new(
          running: record["status"] == "Running",
          cpus: Integer(record["cpus"]),
          memory_gib: (Integer(record["memory"]).to_f / GIB).round,
        )
      end
      nil
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    # Names of the containers running inside the VM, asked from inside it so
    # the same argv works whether the caller reaches colima directly or via
    # sudo as another user.
    #
    # @return [Array<String>]
    sig { returns(T::Array[String]) }
    def running_containers
      T.unsafe(@executor).capture("colima", "ssh", "--", "docker", "ps", "--format", "{{.Names}}")
        .lines.map(&:strip).reject(&:empty?)
    end
  end
end
