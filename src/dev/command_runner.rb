# typed: strict
# frozen_string_literal: true

require "shellwords"

require "dev/cli/ui"
require "dev/command"
require "dev/credentials"
require "build_container"
require "shadowenv_llvm"
require "shadowenv_python"
require "shadowenv_ruby"

module Dev
  # Runs dev commands by handing the process over to the child. Dev prints a
  # colored header (command name) and then, by default, exec-replaces itself:
  #
  # - repl commands: the bare shell command (no footer, for interactive
  #   sessions)
  # - non-repl commands: a shell wrapper that runs the command and prints
  #   ✓ Done / ✗ Failed based on exit code
  #
  # In wait mode (wait: true) the same commands run spawn-and-wait instead of
  # exec-replace: the child is waited on, and a failure raises a typed error
  # describing its shape — CommandFailedError (nonzero exit, carrying the
  # status), CommandKilledError (signal termination, carrying the signal), or
  # CommandSpawnError (the child never started) — so a caller with
  # success-contingent post-steps (e.g. Runner's installed stamp) can sequence
  # them after execute while preserving the child's exit code (#85).
  #
  # The child has full terminal access — CLI::UI features (frames, spinners,
  # prompts) all work natively without any interception.
  #
  # Before every command, ensures the project's shadowenv Ruby environment is
  # provisioned (fast-path: skips if .shadowenv.d/510_ruby.lisp is current).
  #
  # When a build container is configured and the command opts in (default),
  # the command runs inside the container via `docker run`. Otherwise it runs
  # locally via `shadowenv exec`.
  class CommandRunner
    extend T::Sig

    # Raised in wait mode when the child command exits nonzero, carrying its
    # exit status so the caller can skip success-contingent post-steps and
    # exit with the child's code. (Exec-replace mode never raises — the
    # child's status becomes the process's own.)
    class CommandFailedError < StandardError
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :exit_status

      sig { params(exit_status: Integer).void }
      def initialize(exit_status:)
        @exit_status = T.let(exit_status, Integer)
        super("command failed with exit status #{exit_status}")
      end
    end

    # Raised in wait mode when a signal terminates the child, carrying the
    # signal number so the caller can exit 128 + signal (shell convention).
    class CommandKilledError < StandardError
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :signal

      sig { params(signal: Integer).void }
      def initialize(signal:)
        @signal = T.let(signal, Integer)
        super("command killed by signal #{signal}")
      end
    end

    # Raised in wait mode when the child could not be spawned at all (e.g.
    # the executable is missing), so no child exit status exists.
    class CommandSpawnError < StandardError
      extend T::Sig

      sig { void }
      def initialize
        super("command could not be spawned")
      end
    end

    sig do
      params(
        ui: Dev::Cli::Ui,
        ruby_version: String,
        python_version: T.nilable(String),
        build_container: T.nilable(Dev::BuildContainerConfig),
        project_root: Pathname,
        wait: T::Boolean,
      ).void
    end
    def initialize(ui:, ruby_version:, python_version: nil, build_container: nil, project_root: Dev.target_project_root,
      wait: false)
      @ui = T.let(ui, Dev::Cli::Ui)
      @ruby_version = T.let(ruby_version, String)
      @python_version = T.let(python_version, T.nilable(String))
      @build_container = T.let(build_container, T.nilable(Dev::BuildContainerConfig))
      @project_root = T.let(project_root, Pathname)
      @wait = T.let(wait, T::Boolean)
    end

    sig { params(cmd: ProjectCommand, args: T::Array[String]).void }
    def run(cmd, args: [])
      shell_command = build_shell_command(cmd.run, args)
      @ui.print_header(shell_command)

      if use_container?(cmd)
        run_in_container(cmd, shell_command)
      else
        ensure_shadowenv_provisioned!
        if cmd.repl
          run_bare(shell_command)
        else
          run_with_status_footer(shell_command)
        end
      end
    end

    private

    sig { params(cmd: ProjectCommand).returns(T::Boolean) }
    def use_container?(cmd)
      !@build_container.nil? && cmd.container
    end

    # Whether the resolved image should be published to the shared registry.
    # Off by default — a normal local build/run must never push. The
    # provisioning step (e.g. CI's `dev up`) opts in by setting
    # DEV_PUBLISH_IMAGE, so it populates the registry that every other machine
    # — and a from-scratch CI runner — pulls from. Gated by an env var rather
    # than the command name so any project's provisioning can enable it without
    # dev hard-coding which command is the publisher.
    sig { returns(T::Boolean) }
    def publish_image?
      ENV["DEV_PUBLISH_IMAGE"] == "1"
    end

    sig { params(_cmd: ProjectCommand, shell_command: String).void }
    def run_in_container(_cmd, shell_command)
      config = T.must(@build_container)
      image_tag = BuildContainer.ensure_image!(
        config,
        project_root: @project_root,
        push: false,
        publish: publish_image?,
        build_args_provider: -> { resolve_build_args(config) },
        secrets_provider: -> { resolve_build_secrets(config) },
      )
      docker_argv = container_command(config, image_tag, shell_command)

      Dir.chdir(@project_root)
      run_child(docker_argv)
    end

    # docker argv for a containerized command: a `docker exec` into the reused
    # long-lived container when persist is set (its writable layer keeps the
    # build tool's incremental state across commands), else a one-shot `docker
    # run --rm`.
    #
    # @param config        [Dev::BuildContainerConfig]
    # @param image_tag      [String]
    # @param shell_command [String]
    # @return [Array<String>]
    sig do
      params(config: Dev::BuildContainerConfig, image_tag: String, shell_command: String)
        .returns(T::Array[String])
    end
    def container_command(config, image_tag, shell_command)
      # Resolve configured volumes onto the version-keyed install dirs the
      # integrations publish, so the command mounts the exact locked version.
      volumes = BuildContainer.resolve_versioned_volumes(config.volumes, project_root: @project_root)

      if config.persist
        container = BuildContainer.ensure_service!(
          image_tag, project_root: @project_root, volumes: volumes,
        )
        BuildContainer.docker_exec_command(
          container, shell_cmd: shell_command, env: resolve_run_env(config),
        )
      else
        BuildContainer.docker_run_command(
          image_tag,
          project_root: @project_root,
          shell_cmd: shell_command,
          volumes: volumes,
          env: resolve_run_env(config),
        )
      end
    end

    # Resolve docker build args declared in dev.yml from Dev::Credentials.
    # Only invoked when the image actually needs building. Normally `dev up`
    # has already prompted and stored these, so this resolves silently.
    #
    # @param config [Dev::BuildContainerConfig]
    # @return [Hash{String => String}]
    sig { params(config: Dev::BuildContainerConfig).returns(T::Hash[String, String]) }
    def resolve_build_args(config)
      Dev::Credentials.resolve_build_args(config.build_args)
    end

    # Resolve BuildKit build secrets declared in dev.yml from Dev::Credentials.
    # Same shape and lazy timing as build args (only on a cache miss), but the
    # values are mounted as BuildKit secrets rather than baked into image layers.
    #
    # @param config [Dev::BuildContainerConfig]
    # @return [Hash{String => String}]
    sig { params(config: Dev::BuildContainerConfig).returns(T::Hash[String, String]) }
    def resolve_build_secrets(config)
      Dev::Credentials.resolve_build_args(config.build_secrets)
    end

    # Resolve runtime env vars (build.container.run_env) for `docker run -e`.
    #
    # Best-effort and non-interactive by design: an entry is injected only
    # when its value is already available (ENV override, then stored
    # credential), and silently skipped otherwise. run_env applies to every
    # containerized command, so a missing runtime secret must not block or
    # prompt commands that don't need it (e.g. `dev build` when the relevant
    # provisioning step already ran). The provisioning command that *does*
    # need it is responsible for making the value available (e.g. exporting
    # it before invoking the command).
    #
    # @param config [Dev::BuildContainerConfig]
    # @return [Hash{String => String}]
    sig { params(config: Dev::BuildContainerConfig).returns(T::Hash[String, String]) }
    def resolve_run_env(config)
      return {} if config.run_env.empty?

      config.run_env.each_with_object({}) do |(name, credential_ref), resolved|
        namespace, key = credential_ref.split("/", 2)
        value = ENV[name] || Dev::Credentials.load(T.must(namespace), T.must(key))
        resolved[name] = value if value
      end
    end

    sig { params(run_str: String, args: T::Array[String]).returns(String) }
    def build_shell_command(run_str, args)
      return run_str if args.empty?

      "#{run_str} #{args.shelljoin}"
    end

    sig { returns(T::Hash[String, T.nilable(String)]) }
    def child_env
      rubylib = [Dev::DEV_LIB_DIR, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR)
      { "GEM_HOME" => nil, "RUBYLIB" => rubylib }
    end

    # Toolchain provisioning: each toolchain the project uses gets its shadowenv
    # set up before command execution — Ruby (always), then LLVM and Python when
    # the project declares them. Each ensure_* is a fast provisioned?-guarded
    # no-op after the first run. (A registry pattern per #21 would fold these into
    # a list; three explicit, guarded steps stay readable for now.)
    sig { void }
    def ensure_shadowenv_provisioned!
      project_root = @project_root
      ShadowenvRuby.ensure!(ruby_version: @ruby_version, project_root: project_root)

      ensure_llvm_provisioned!(project_root)
      ensure_python_provisioned!(project_root)
    end

    # Provision the project's Python venv (Homebrew interpreter + .venv +
    # 540_python.lisp) when a `python` version is declared. No-op otherwise.
    sig { params(project_root: Pathname).void }
    def ensure_python_provisioned!(project_root)
      version = @python_version
      return if version.nil? || version.empty?

      return if ShadowenvPython.provisioned?(version, project_root: project_root)

      ShadowenvPython.setup!(python_version: version, project_root: project_root)
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
    # @return [void]
    sig { params(shell_command: String).void }
    def run_bare(shell_command)
      Dir.chdir(@project_root)
      run_child([child_env, "shadowenv", "exec", "--", "sh", "-c", shell_command])
    end

    # Runs the command inside a shell wrapper that prints a colored
    # success/failure footer based on the exit code (and preserves it).
    #
    # @param shell_command [String]
    # @return [void]
    sig { params(shell_command: String).void }
    def run_with_status_footer(shell_command)
      Dir.chdir(@project_root)
      run_child([child_env, "shadowenv", "exec", "--", "sh", "-c", <<~SH])
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

    # Hands the assembled argv (optional env hash first) to the child process.
    # Exec-replace by default — the right shape for a leaf command: TTY and
    # signal passthrough, no double process tree. In wait mode, spawn-and-wait
    # instead, so control returns to the caller's post-execute steps.
    #
    # @param argv [Array] Kernel.exec / Kernel.system argv
    # @return [void]
    # @raise [CommandFailedError] in wait mode, when the child exits nonzero
    # @raise [CommandKilledError] in wait mode, when a signal kills the child
    # @raise [CommandSpawnError] in wait mode, when the child never started
    sig { params(argv: T::Array[T.untyped]).void }
    def run_child(argv)
      return Kernel.exec(*T.unsafe(argv)) unless @wait

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
