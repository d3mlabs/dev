# typed: strict
# frozen_string_literal: true

require "pathname"
require "shellwords"

require "dev/ui"
require "dev/command"
require "dev/container_workspace"
require "dev/environment_image"
require "dev/host_rule"
require "dev/lifecycle/snapshot_sync"
require "dev/placement"
require "dev/project_container"
require "dev/shadowenv_llvm"

module Dev
  # Runs dev commands by handing the process over to the child. Dev prints a
  # colored header (command name) and then runs the shell command:
  #
  # - repl commands: the bare shell command (no footer, for interactive
  #   sessions)
  # - non-repl commands: a shell wrapper that runs the command and prints
  #   ✓ Done / ✗ Failed based on exit code
  #
  # The two child-process shapes are two public messages, mirroring
  # ProjectExecutor's seam: exec_into exec-replaces the process (the child's
  # exit status becomes dev's own); run_waiting spawns and waits, and a
  # failure raises a typed error describing its shape — CommandFailedError
  # (nonzero exit, carrying the status), CommandKilledError (signal
  # termination, carrying the signal), or CommandSpawnError (the child never
  # started) — so a caller with success-contingent post-steps (e.g. the
  # installed stamp) can sequence them after execute while preserving the
  # child's exit code (#85).
  #
  # The child has full terminal access — CLI::UI features (frames, spinners,
  # prompts) all work natively without any interception.
  #
  # Before every command, ensures the project's shadowenv Ruby environment is
  # provisioned (fast-path: skips if the project's ruby lisp is current).
  #
  # Where a command runs is `placement`: the command's environment — its
  # `environment:` bound against the lock at load (ProjectCommand#placement,
  # dev#409) — is an image or the host. The host means `shadowenv exec`
  # here, silently. An image means the project's container of it, reached
  # as a remote that happens to be local (ADR-0008, dev#421): the tree
  # crosses as a snapshot branch for the command's duration
  # (Lifecycle::SnapshotSync), one dim line says so (`→ in <image>
  # (container), snapshot <sha>`), and the container fetches the snapshot
  # into its own workspace and runs the command there (ProjectContainer),
  # with the image's resolved `run_env` and the host's gh token as
  # GH_TOKEN. The container path always waits — the snapshot branch is
  # deleted after — and the container's exit status becomes dev's own:
  # exec_into exits with it, run_waiting raises CommandFailedError over
  # it.
  #
  # Inside a dev-managed container (HostRule#inside_container?) there is no
  # further container to reach for: every command runs directly at the
  # project root, under `shadowenv exec` like any other. The interpreters
  # it finds there are `dev deps install`'s doing — Ruby and Python are
  # brew pins activated in the project shadowenv by the install, on the
  # host and inside the container alike — and the host-only LLVM is left
  # to the image.
  #
  # On a host that *is* the command's environment there is no container to
  # reach for either — the host rule (HostRule, ADR-0007 as amended by
  # dev#308), asked of the command's image: a host provisioned from the
  # image runs its commands directly, under the host's shadowenv, as a host
  # command does. Inside a container, the same rule refuses work the
  # container is not the image for (drift): the container cannot replace
  # itself, the host can.
  class CommandRunner
    extend T::Sig

    # The argv that precedes `sh -c` for a direct run: the project's
    # shadowenv, whose lisps `dev deps install` wrote — the locked kegs on
    # PATH, the locked Ruby and Python activated — on the host and inside
    # the container alike.
    SHELL_PREFIX = T.let(%w[shadowenv exec --].freeze, T::Array[String])

    # Raised by run_waiting when the child command exits nonzero, carrying
    # its exit status so the caller can skip success-contingent post-steps
    # and exit with the child's code. (exec_into never raises — the child's
    # status becomes the process's own.)
    class CommandFailedError < StandardError
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :exit_status

      sig { params(exit_status: Integer).void }
      def initialize(exit_status:)
        @exit_status = exit_status
        super("command failed with exit status #{exit_status}")
      end
    end

    # Raised by run_waiting when a signal terminates the child, carrying the
    # signal number so the caller can exit 128 + signal (shell convention).
    class CommandKilledError < StandardError
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :signal

      sig { params(signal: Integer).void }
      def initialize(signal:)
        @signal = signal
        super("command killed by signal #{signal}")
      end
    end

    # Raised by run_waiting when the child could not be spawned at all (e.g.
    # the executable is missing), so no child exit status exists.
    class CommandSpawnError < StandardError
      extend T::Sig

      sig { void }
      def initialize
        super("command could not be spawned")
      end
    end

    # @param ui [Dev::Ui] the header and the crossing line
    # @param project_root [Pathname] the checkout
    # @param host_rule [Dev::HostRule] whether an image's work runs here —
    #   and whether this dev already runs inside a container
    # @param containers [Dev::ProjectContainer] the way into the project's
    #   containers (the one instance the lifecycle verbs share)
    # @param sync [Dev::Lifecycle::SnapshotSync] the sync step over the checkout
    sig do
      params(
        ui: Dev::Ui,
        project_root: Pathname,
        host_rule: Dev::HostRule,
        containers: Dev::ProjectContainer,
        sync: Dev::Lifecycle::SnapshotSync,
      ).void
    end
    def initialize(ui:, project_root:, host_rule: Dev::HostRule.new,
                   containers: Dev::ProjectContainer.new(project_root:), sync: Dev::Lifecycle::SnapshotSync.new(root: project_root))
      @ui = ui
      @project_root = project_root
      @host_rule = host_rule
      @containers = containers
      @sync = sync
    end

    # Hand the process over to the command: exec-replace, the right shape
    # for a leaf command (TTY and signal passthrough, no double process
    # tree); a command in the container is waited for and its status
    # exited with. Never returns in production.
    #
    # @param cmd [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @return [void]
    sig { params(cmd: ProjectCommand, args: T::Array[String]).void }
    def exec_into(cmd, args: [])
      run(cmd, args:, wait: false)
    end

    # Run the command spawn-and-wait, so control returns to the caller's
    # success-contingent post-steps.
    #
    # @param cmd [ProjectCommand]
    # @param args [Array<String>] argv after the command name
    # @return [void]
    # @raise [CommandFailedError] when the child fails
    sig { params(cmd: ProjectCommand, args: T::Array[String]).void }
    def run_waiting(cmd, args: [])
      run(cmd, args:, wait: true)
    end

    private

    # The shared pipeline behind both public messages; wait picks the
    # child-process shape at the run_child boundary.
    #
    # @param cmd [ProjectCommand]
    # @param args [Array<String>]
    # @param wait [Boolean]
    # @return [void]
    sig { params(cmd: ProjectCommand, args: T::Array[String], wait: T::Boolean).void }
    def run(cmd, args:, wait:)
      shell_command = build_shell_command(cmd.run, args)
      @ui.print_header(shell_command)

      placement = placement(cmd)
      case placement
      when Placement::Host
        ensure_shadowenv_provisioned!
        if cmd.repl
          run_bare(shell_command, wait:)
        else
          run_with_status_footer(shell_command, wait:)
        end
      when Placement::Image
        run_in_container(placement.image, shell_command, wait:)
      else
        # simplecov:disable — the sealed placement has no third shape;
        # T.absurd keeps the static proof.
        T.absurd(placement)
        # simplecov:enable
      end
    end

    # Where the command runs on this machine: here, or in a container of
    # its image. Here when the command's environment is the host, when this
    # host was provisioned from the image (the host rule), or when we are
    # already inside a container of it; the image otherwise. Inside a
    # container that is not the image's, the work is refused.
    #
    # @param cmd [ProjectCommand] bound at load (ProjectCommand#placement!)
    # @return [Placement] Host to run here, Image to enter a container of it
    # @raise [ProjectCommand::UnboundPlacementError] when the lock could not place it at load
    # @raise [HostRule::ContainerDriftError] inside a container that is not the lock's image
    sig { params(cmd: ProjectCommand).returns(Placement) }
    def placement(cmd)
      placement = cmd.placement!
      return placement unless placement.is_a?(Placement::Image)

      image = placement.image
      @host_rule.assert_container_is!(image) if @host_rule.inside_container?
      @host_rule.enters_container?(image) ? placement : Placement::Host.new
    end

    # The crossing: the one moment the mental model can be wrong, so the
    # one line dev prints about where a command runs (a native or host run
    # prints nothing beyond the footer). The tree crosses as a snapshot for
    # the command's duration; the container fetches it and runs the
    # command in its workspace; its exit status is the verdict here.
    #
    # @param image [EnvironmentImage] the command's environment
    # @param shell_command [String]
    # @param wait [Boolean] raise on failure (run_waiting) or exit with the status (exec_into)
    # @return [void]
    # @raise [CommandFailedError] when waited for and the container's command exits nonzero
    # @raise [EngineResourcesCheck::UndersizedEngineError] when the engine falls short of the project's floor
    sig { params(image: EnvironmentImage, shell_command: String, wait: T::Boolean).void }
    def run_in_container(image, shell_command, wait:)
      status = @sync.sync(runner: ContainerWorkspace::RUNNER) do |snapshot|
        @ui.print_remote_crossing(destination: @containers.destination(image), snapshot: snapshot.short_sha)
        @containers.run(image, argv: ["sh", "-c", shell_command], snapshot:)
      end
      if wait
        raise CommandFailedError.new(exit_status: status) unless status.zero?
      else
        # The exec shape has no caller to return to: the container's status
        # is the process's own, as an exec-replaced child's would be.
        Kernel.exit(status)
      end
    end

    sig { params(run_str: String, args: T::Array[String]).returns(String) }
    def build_shell_command(run_str, args)
      return run_str if args.empty?

      "#{run_str} #{args.shelljoin}"
    end

    # The direct run's child env: the inherited one plus dev's lib on
    # RUBYLIB, so a project's dev-aware scripts (bin/setup.rb, bin/tc.rb)
    # can require it. Nothing is cleared here — env hygiene is bin/dev's
    # entrypoint, once (see Dev::Deps::ShadowenvExec, the other `shadowenv
    # exec` seam, for why a nil'd key here is a regression: this method
    # once nil'd GEM_HOME on its own and reproduced dev#274's LoadError).
    # RUBYLIB is set, not cleared: the entrypoint stripped the caller's
    # before any Ruby ran, so what this layers on is dev's own.
    sig { returns(T::Hash[String, T.nilable(String)]) }
    def child_env
      rubylib = [Dev::DEV_LIB_DIR, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR)
      { "RUBYLIB" => rubylib }
    end

    # Toolchain provisioning before command execution. The interpreters are
    # project dependencies — `ruby` / `python` pins in dependencies.rb that
    # `dev deps install` installs and activates in the project shadowenv —
    # so nothing is provisioned for them here. LLVM is the one host
    # toolchain still set up at run time, a fast provisioned?-guarded no-op
    # after the first run (#297 moves it into the dependency graph too).
    #
    # Inside the container LLVM is the image's concern: nothing to do.
    sig { void }
    def ensure_shadowenv_provisioned!
      return if @host_rule.inside_container?

      ensure_llvm_provisioned!(@project_root)
    end

    sig { params(project_root: Pathname).void }
    def ensure_llvm_provisioned!(project_root)
      return if ShadowenvLlvm.ci_or_linux?
      return unless ShadowenvLlvm.project_needs_llvm?(project_root)

      prefix = ShadowenvLlvm.detect_llvm_prefix
      return unless prefix
      return if ShadowenvLlvm.provisioned?(prefix, project_root: project_root)

      ShadowenvLlvm.setup!(project_root: project_root, llvm_prefix: prefix)
    end

    # Runs the bare shell command with no footer, so an interactive (repl)
    # session owns the terminal end to end.
    #
    # @param shell_command [String]
    # @param wait [Boolean]
    # @return [void]
    sig { params(shell_command: String, wait: T::Boolean).void }
    def run_bare(shell_command, wait:)
      Dir.chdir(@project_root)
      run_child([child_env, *SHELL_PREFIX, "sh", "-c", shell_command], wait:)
    end

    # Runs the command inside a shell wrapper that prints a colored
    # success/failure footer based on the exit code (and preserves it).
    #
    # @param shell_command [String]
    # @param wait [Boolean]
    # @return [void]
    sig { params(shell_command: String, wait: T::Boolean).void }
    def run_with_status_footer(shell_command, wait:)
      Dir.chdir(@project_root)
      run_child([child_env, *SHELL_PREFIX, "sh", "-c", <<~SH], wait:)
        #{shell_command}
        __dev_status=$?
        if [ $__dev_status -eq 0 ]; then
          if [ -t 1 ]; then
            printf '\\033[32m✓\\033[0m Done\\n'
          else
            echo 'Done'
          fi
        else
          if [ -t 1 ]; then
            printf '\\033[31m✗\\033[0m Failed (exit %d)\\n' "$__dev_status"
          else
            printf 'Failed (exit %d)\\n' "$__dev_status"
          fi
          exit $__dev_status
        fi
      SH
    end

    # Hands the assembled argv (optional env hash first) to the child
    # process: exec-replace for exec_into, spawn-and-wait for run_waiting.
    #
    # @param argv [Array] Kernel.exec / Kernel.system argv
    # @param wait [Boolean]
    # @return [void]
    # @raise [CommandFailedError] when a waited child exits nonzero
    # @raise [CommandKilledError] when a signal kills the waited child
    # @raise [CommandSpawnError] when the waited child never started
    sig { params(argv: T::Array[T.untyped], wait: T::Boolean).void }
    def run_child(argv, wait:)
      return Kernel.exec(*T.unsafe(argv)) unless wait

      # Kernel.system returns true on a zero exit, false when the child ran
      # and failed ($? has the details), and nil when the child could not be
      # spawned at all. The nil return is the reliable spawn-failure signal:
      # $? can still be set then (a synthetic exit-127 status), so it cannot
      # distinguish "never started" from "ran and failed".
      spawned = Kernel.system(*T.unsafe(argv))
      return if spawned

      raise CommandSpawnError if spawned.nil?

      raise child_failure($?)
    end

    # Classifies a failed child's status: killed by a signal, or a plain
    # nonzero exit.
    #
    # @param status [Process::Status]
    # @return [CommandFailedError, CommandKilledError]
    sig { params(status: Process::Status).returns(T.any(CommandFailedError, CommandKilledError)) }
    def child_failure(status)
      return CommandKilledError.new(signal: T.must(status.termsig)) if status.signaled?

      CommandFailedError.new(exit_status: T.must(status.exitstatus))
    end
  end
end
