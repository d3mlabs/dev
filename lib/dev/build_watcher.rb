# typed: strict
# frozen_string_literal: true

require "open3"
require "stringio"

require "dev/container_engine"

module Dev
  # Runs a long containerized build with hung-build detection and bounded retries.
  #
  # The base-game compile deadlocks intermittently under Rosetta: a clang++ worker
  # crashes, leaves a zombie, and UnrealBuildTool waits forever on a child that
  # will never report — the container sits at ~0% CPU producing no output. A plain
  # `system(docker run …)` would block indefinitely.
  #
  # This watcher distinguishes three terminal situations and reacts to each, so a
  # transient emulation flake self-heals while a genuine compile error still fails
  # fast (no infinite retry loop):
  #
  #   - exit 0                         -> success
  #   - alive, stalled (no output for
  #     stall_after AND container CPU
  #     ~0% AND guest load ~0)         -> a hang: kill the container and retry
  #   - non-zero exit:
  #       * Rosetta/clang crash sig    -> a transient crash: retry
  #       * real compile-error sig     -> fail fast (don't retry)
  #       * neither                    -> fail fast (surface the unknown failure)
  #
  # Guest load matters because container CPU alone misreads I/O-bound phases:
  # a build reading a big tree through virtiofs (a cold engine mount) spends
  # its time in D-state while the host-side VM process does the work — the
  # container's cgroup shows ~0% CPU and UBT prints nothing until the first
  # action completes, which reads exactly like the deadlock. D-state processes
  # count into the guest's load average, so "CPU idle but load busy" is an
  # I/O-bound build to leave alone, while the real zombie-deadlock (UBT
  # sleeping on a child that will never report) shows load ~0 as well.
  #
  # Retries are capped (max_attempts) and rely on the build tool's atomic
  # intermediate writes, so a retry resumes incrementally rather than from scratch.
  #
  # Policy (stalled?, classify_failure) is pure and unit-tested; the OS mechanism
  # (run_once and its docker probes) is isolated so it can be overridden in tests.
  class BuildWatcher
    extend T::Sig

    # Seconds without any build output before the build is *eligible* to be judged
    # stalled (combined with near-zero CPU and load, to avoid killing a
    # slow-but-working compile action). Sized for the worst legitimate silence:
    # a cold Win64 compile start under wine+Rosetta (prefix init + the first
    # SharedPCH batch) produces no output for well over five minutes.
    DEFAULT_STALL_AFTER = 900
    # Container CPU percent at or below which it counts as "doing nothing".
    DEFAULT_CPU_FLOOR = 5.0
    # Guest 1-minute load average at or below which it counts as "doing
    # nothing". One build owns the VM, so any D-state I/O work shows up here.
    DEFAULT_LOAD_FLOOR = 0.5
    # How often to probe liveness/CPU while the build runs.
    DEFAULT_POLL = 15
    # Total attempts before giving up (fail fast on a genuinely broken build).
    DEFAULT_MAX_ATTEMPTS = 5

    # Crash signatures worth retrying (flaky Rosetta/clang emulation failures).
    CRASH_SIGNATURES = T.let([
      /rosetta error/i,
      /segmentation fault/i,
      /caught signal/i,
      /clang\+\+.*(?:crashed|terminated|killed|signal)/i,
      /llvm error/i,
      /internal compiler error|\bICE\b/i,
      /unable to spawn process|posix_spawn failed/i,
    ].freeze, T::Array[Regexp])

    # Genuine compile/link errors — fail fast, retrying won't help.
    COMPILE_ERROR_SIGNATURES = T.let([
      /(?:^|\s)error:\s/i,
      /fatal error:/i,
      /undefined reference to/i,
      /ld(?:\.lld)?:\s*error/i,
      /\bUnrealBuildTool\b.*\bERROR\b/,
    ].freeze, T::Array[Regexp])

    Result = Struct.new(:outcome, :output) # outcome: :success | :stalled | :failed

    # @param container_name [String] the `docker run --name` of the watched build,
    #   so a stall can be killed by name
    # @param engine         [Dev::ContainerEngine] the engine the watched build
    #   rides — its probes (stats) and interventions (kill, rm) must reach the
    #   same daemon the build runs on
    # @param stall_after    [Integer] seconds of no output before stall-eligible
    # @param cpu_floor      [Float]   CPU% at/under which counts as idle
    # @param load_floor     [Float]   guest 1-min load at/under which counts as idle
    # @param poll           [Integer] probe interval in seconds
    # @param max_attempts   [Integer] retry cap
    # @param out            [IO, StringIO] progress/diagnostic stream
    sig do
      params(
        container_name: String,
        engine: Dev::ContainerEngine,
        stall_after: Integer,
        cpu_floor: Float,
        load_floor: Float,
        poll: Integer,
        max_attempts: Integer,
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(container_name:, engine:, stall_after: DEFAULT_STALL_AFTER, cpu_floor: DEFAULT_CPU_FLOOR,
                   load_floor: DEFAULT_LOAD_FLOOR, poll: DEFAULT_POLL, max_attempts: DEFAULT_MAX_ATTEMPTS,
                   out: $stderr)
      @container_name = container_name
      @engine = engine
      @stall_after = stall_after
      @cpu_floor = cpu_floor
      @load_floor = load_floor
      @poll = poll
      @max_attempts = max_attempts
      @out = out
    end

    # Run argv with stall detection and bounded retries.
    #
    # @param argv [Array<String>] the docker run command to execute
    # @return [Boolean] true if a run succeeded within the attempt budget
    sig { params(argv: T::Array[String]).returns(T::Boolean) }
    def run(argv)
      @max_attempts.times do |attempt|
        result = run_once(argv)
        return true if result.outcome == :success

        reason = retry_reason(result)
        return false unless reason

        @out.puts ">>> build-watcher: #{reason} (attempt #{attempt + 1}/#{@max_attempts}); retrying"
      end
      @out.puts ">>> build-watcher: giving up after #{@max_attempts} attempts"
      false
    end

    # Whether a still-running build looks hung: silent long enough AND idle CPU
    # AND idle guest load. All three are required so a legitimately slow (but
    # working) compile action — CPU-busy, or I/O-bound in D-state where only
    # the load average registers — is never killed.
    #
    # @param idle_seconds [Numeric] seconds since the last build output
    # @param cpu_percent  [Numeric] current container CPU percent
    # @param load_avg     [Numeric] current guest 1-minute load average
    # @return [Boolean]
    sig { params(idle_seconds: Numeric, cpu_percent: Numeric, load_avg: Numeric).returns(T::Boolean) }
    def stalled?(idle_seconds:, cpu_percent:, load_avg:)
      idle_seconds >= @stall_after && cpu_percent <= @cpu_floor && load_avg <= @load_floor
    end

    # Classify a failed (non-zero) run's output. Crash signatures take precedence
    # over compile-error signatures: a Rosetta crash often *also* prints a cascade
    # "error:", but it's the transient cause we should retry; a real compile error
    # has no crash signature.
    #
    # @param output [String] captured combined output
    # @return [Symbol] :retry (transient) or :fail (genuine)
    sig { params(output: String).returns(Symbol) }
    def classify_failure(output)
      return :retry if CRASH_SIGNATURES.any? { |re| output.match?(re) }

      :fail # compile error or unknown: don't loop on a broken build
    end

    private

    # @param result [Result]
    # @return [String, nil] human reason to retry, or nil to stop
    sig { params(result: Result).returns(T.nilable(String)) }
    def retry_reason(result)
      return "hung build detected (no output + idle CPU)" if result.outcome == :stalled
      return "transient crash signature" if classify_failure(result.output) == :retry

      nil
    end

    # Spawn the build, stream + capture its output, and watch for a stall.
    # Isolated as the single OS-touching seam so the retry/classify policy can be
    # tested without real processes.
    #
    # @param argv [Array<String>]
    # @return [Result]
    sig { params(argv: T::Array[String]).returns(Result) }
    def run_once(argv)
      free_container_name
      last_output = now
      captured = +""

      # The argv already carries the engine's argv prefix (the composer built
      # it); the engine's env (e.g. the colima DOCKER_HOST) rides the spawn.
      # T.unsafe: popen2e's fixed env-or-command first parameter can't be
      # matched against a runtime-sized splat (error 7019).
      T.unsafe(Open3).popen2e(@engine.env, *argv) do |stdin, out, wait_thr|
        stdin.close
        reader = Thread.new do
          out.each_line do |line|
            @out.print(line)
            captured << line
            last_output = now
          end
        end

        stalled = wait_or_kill(wait_thr) { now - last_output }
        reader.join
        next Result.new(:stalled, captured) if stalled

        Result.new(wait_thr.value.success? ? :success : :failed, captured)
      end
    end

    # Poll until the process exits; if it goes silent and idle, kill it.
    #
    # @param wait_thr [Process::Waiter]
    # @yieldreturn [Numeric] seconds since last output
    # @return [Boolean] true if killed due to stall
    sig { params(wait_thr: Process::Waiter, blk: T.proc.returns(Float)).returns(T::Boolean) }
    def wait_or_kill(wait_thr, &blk)
      while wait_thr.alive?
        sleep @poll
        next unless wait_thr.alive?
        next unless stalled?(idle_seconds: yield, cpu_percent: container_cpu, load_avg: container_load)

        kill_container
        wait_thr.join
        return true
      end
      false
    end

    # Current container CPU percent via `docker stats`. Best-effort: an unreadable
    # value reports as idle so a truly silent container can still be reclaimed
    # (the engine's capture already collapses failures to empty output).
    #
    # @return [Float]
    sig { returns(Float) }
    def container_cpu
      out = @engine.capture(["stats", "--no-stream", "--format", "{{.CPUPerc}}", @container_name])
      out.strip.delete("%").to_f
    end

    # Guest 1-minute load average, read from inside the container. /proc/loadavg
    # is kernel-global, so this is the whole VM's load — the right scope, since
    # one build owns the VM and D-state virtiofs I/O (invisible to the cgroup
    # CPU stat) counts into it. Best-effort like container_cpu: an unreadable
    # value reports as idle so a truly dead container can still be reclaimed.
    #
    # @return [Float]
    sig { returns(Float) }
    def container_load
      out = @engine.capture(["exec", @container_name, "cat", "/proc/loadavg"])
      out.split.first.to_f
    end

    # @return [void]
    sig { void }
    def kill_container
      @out.puts ">>> build-watcher: killing hung container #{@container_name}"
      @engine.run(["kill", @container_name], out: File::NULL, err: File::NULL)
    end

    # Remove any container left by a previous attempt so this attempt's
    # `docker run --name` can't collide. A stalled container we killed, or one
    # that exited non-zero, persists until removed — and the prewarm run can't use
    # `--rm` because the container must survive for the subsequent `docker commit`.
    # Silent no-op on the first attempt, when nothing by this name exists yet.
    #
    # @return [void]
    sig { void }
    def free_container_name
      @engine.run(["rm", "-f", @container_name], out: File::NULL, err: File::NULL)
    end

    # Monotonic clock so wall-clock changes never skew stall timing.
    #
    # @return [Float]
    sig { returns(Float) }
    def now
      # CLOCK_MONOTONIC with the default :float_second unit always yields a
      # Float; the cast narrows Sorbet's T.any(Float, Integer) stdlib signature.
      T.cast(Process.clock_gettime(Process::CLOCK_MONOTONIC), Float)
    end
  end
end
