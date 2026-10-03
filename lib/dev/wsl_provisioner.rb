# typed: strict
# frozen_string_literal: true

require "stringio"

require "dev/engine_resources"
require "dev/process_executor"
require "dev/wsl_config"
require "dev/wsl_host"

module Dev
  # The colima ratchet, `.wslconfig` edition. On WSL2 the engine VM is sized
  # by `%USERPROFILE%\.wslconfig` (`[wsl2] processors` / `memory`), applied
  # only when the VM next starts — and dev runs *inside* that VM, so it can
  # write the file but never restart it: `wsl --shutdown` would kill dev's own
  # session and every runner service with it. That restart is the user's
  # move, and this class tells them exactly when it is needed.
  #
  # Per field, "current" is the configured value when `.wslconfig` has one,
  # else what the VM observably runs (WSL's defaults). The decision table:
  #
  # - interop disabled: one warning naming the file; the VM is the user's.
  # - hint above the Windows hardware: UnsatisfiableHintError — fail loudly
  #   rather than write a value WSL would silently clamp.
  # - no `.wslconfig` sizes: write the hint for each field WSL's default does
  #   not already meet (a default that is big enough is not pinned, and
  #   undeclared fields stay unset) plus `autoMemoryReclaim=gradual` when
  #   absent.
  # - configured at/above the hint and applied: nothing to do.
  # - configured at/above the hint but the VM still runs the old size: a
  #   written-but-unapplied resize — no rewrite, RestartRequiredError.
  # - undersized, idle (no containers): write max(current, hint) per field,
  #   capped at the hardware, then RestartRequiredError.
  # - undersized, busy: EngineBusyError listing the containers — the restart
  #   the write asks for would kill someone's build.
  #
  # Sizes ratchet up and never shrink: the file is shared by every project on
  # the machine, and `processors` is a cap while `autoMemoryReclaim` hands
  # idle memory back to Windows, so a generous VM costs nothing at rest.
  class WslProvisioner
    extend T::Sig

    # `.wslconfig` asks for more than the VM currently runs; the user must
    # `wsl --shutdown` from Windows and come back.
    class RestartRequiredError < RuntimeError; end

    # The VM is undersized but containers are running in it; the restart a
    # resize needs would kill them.
    class EngineBusyError < RuntimeError; end

    # The repo's hint exceeds the Windows machine's hardware.
    class UnsatisfiableHintError < RuntimeError; end

    # The reclaim mode dev converges when the user has not chosen one: idle
    # VM memory flows back to Windows, which is what makes "never shrink"
    # free and lets `dev engine down` stop dockerd rather than the VM.
    AUTO_MEMORY_RECLAIM = "gradual"

    RESTART_HINT = "From Windows run `wsl --shutdown` (this stops every WSL distro and the runner services in them), " \
      "then `dev up` again."

    # @param host [WslHost] the WSL machine (interop, `.wslconfig`, hardware, observed size)
    # @param executor [#capture] process seam for the local daemon's `docker ps`
    # @param out [IO, StringIO] where the interop-off warning goes
    sig { params(host: WslHost, executor: T.untyped, out: T.any(IO, StringIO)).void }
    def initialize(host: WslHost.new, executor: ProcessExecutor.new, out: $stderr)
      @host = host
      @executor = executor
      @out = out
    end

    # Ensure `.wslconfig` grants (at least) the requested size. See the class
    # doc for the decision table.
    #
    # @param cpus [Integer, nil] VM cpu minimum (repo resources hint)
    # @param memory_gib [Integer, nil] VM memory minimum in GiB
    # @param force [Boolean] write even while containers are running (the
    #   `dev engine up --force` of #187); the restart is still the user's, so
    #   nothing is stopped here
    # @return [void]
    # @raise [UnsatisfiableHintError] when the hint exceeds the hardware
    # @raise [EngineBusyError] when a resize is needed but containers are running
    # @raise [RestartRequiredError] when `.wslconfig` is ahead of the running VM
    # @raise [WslHost::InteropError] when a Windows-side probe fails mid-way
    sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), force: T::Boolean).void }
    def provision!(cpus: nil, memory_gib: nil, force: false)
      unless @host.interop?
        @out.puts "dev: WSL interop is disabled, so %USERPROFILE%\\.wslconfig cannot be converged — " \
          "size the VM yourself ([wsl2] processors= / memory=)."
        return
      end

      hardware = @host.hardware
      if (cpus || 0) > hardware.cpus || (memory_gib || 0) > hardware.memory_gib
        raise UnsatisfiableHintError,
          "this project needs #{describe(cpus, memory_gib)} but the Windows machine has #{hardware} — " \
          ".wslconfig cannot grant more than the hardware. Lower the repo's resources hint, " \
          "or set `engine_resources: warn` on this machine (`dev config set engine_resources warn`)."
      end

      config = @host.config
      observed = @host.observed
      target_cpus = target(config.processors, observed.cpus, cpus, hardware.cpus)
      target_memory = target(config.memory_gib, observed.memory_gib, memory_gib, hardware.memory_gib)
      target_resources = EngineResources.new(
        cpus: target_cpus || observed.cpus, memory_gib: target_memory || observed.memory_gib,
      )
      restart_needed = !observed.satisfies?(
        BuildContainerConfig::Resources.new(cpus: target_cpus, memory_gib: target_memory),
      )

      write_needed = target_cpus != config.processors || target_memory != config.memory_gib ||
        config.auto_memory_reclaim.nil?
      unless write_needed
        raise_restart_required(target_resources, observed, pending: true) if restart_needed
        return
      end

      if restart_needed && !force
        busy = running_containers
        unless busy.empty?
          raise EngineBusyError,
            "the WSL VM has #{observed}; this project needs #{describe(cpus, memory_gib)}, and applying a resize " \
            "means `wsl --shutdown` — but containers are running in it:\n  #{busy.join("\n  ")}\n" \
            "Bring those projects down first (`dev container down` there, or `dev engine down`), then re-run `dev up`."
        end
      end

      @host.write_config(
        config.with(
          processors: target_cpus,
          memory_gib: target_memory,
          auto_memory_reclaim: config.auto_memory_reclaim.nil? ? AUTO_MEMORY_RECLAIM : nil,
        ),
      )
      raise_restart_required(target_resources, observed, pending: false) if restart_needed
    end

    private

    # The value a field should hold in `.wslconfig`:
    #
    # - hint nil: the configured value as-is (capped), or nil — nothing asked.
    # - not configured: nil while WSL's default already meets the hint (no
    #   reason to pin a default), else the hint.
    # - configured: the ratchet max(configured, hint), capped at the hardware.
    #
    # @param configured [Integer, nil] `.wslconfig` value
    # @param observed [Integer] what the VM runs
    # @param hint [Integer, nil] the repo's minimum
    # @param cap [Integer] the hardware
    # @return [Integer, nil]
    sig do
      params(configured: T.nilable(Integer), observed: Integer, hint: T.nilable(Integer), cap: Integer)
        .returns(T.nilable(Integer))
    end
    def target(configured, observed, hint, cap)
      return configured && [configured, cap].min if hint.nil?
      return observed >= hint ? nil : hint if configured.nil?

      [[configured, hint].max, cap].min
    end

    # @param target [EngineResources] what `.wslconfig` now asks for
    # @param observed [EngineResources] what the VM runs
    # @param pending [Boolean] whether the file was already there (nothing rewritten)
    # @raise [RestartRequiredError]
    sig { params(target: EngineResources, observed: EngineResources, pending: T::Boolean).void }
    def raise_restart_required(target, observed, pending:)
      lead = pending ? ".wslconfig already asks for" : ".wslconfig now asks for"
      raise RestartRequiredError,
        "#{lead} #{target} but this VM is running at #{observed} — restart pending. #{RESTART_HINT}"
    end

    # @param cpus [Integer, nil]
    # @param memory_gib [Integer, nil]
    # @return [String] the hint as prose, "any" for undeclared fields
    sig { params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer)).returns(String) }
    def describe(cpus, memory_gib)
      "#{cpus || "any"} cpus / #{memory_gib || "any"} GiB"
    end

    # @return [Array<String>] names of containers the local daemon is running
    sig { returns(T::Array[String]) }
    def running_containers
      T.unsafe(@executor).capture("docker", "ps", "--format", "{{.Names}}").lines.map(&:strip).reject(&:empty?)
    end
  end
end
