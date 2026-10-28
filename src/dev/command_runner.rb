# typed: strict
# frozen_string_literal: true

require "shellwords"

require "dev/cli/ui"
require "dev/command"
require "dev/credentials"
require "dev/build_container"
require "dev/container_context"
require "dev/container_engine"
require "dev/container_github_token"
require "dev/host_rule"
require "dev/project_images"
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
  # Where a command runs is `placement`: the command's environment
  # (ProjectImages#for — its `runs_on:`, or the project's one image) is an
  # image or the host. An image means `docker run` / `docker exec` in a
  # container of it; the host means `shadowenv exec` here. A command run
  # inside carries the image's resolved `run_env` and the host's gh token
  # as GH_TOKEN (ContainerGithubToken) — the same `-e` the container's own
  # deps install gets, so a command that calls `gh` inside (a publisher's
  # `gh release create`) has the auth the host holds.
  #
  # Inside a dev-managed container (ContainerContext.inside?) there is no
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

    # @param images [Dev::ProjectImages] the project's images and where each
    #   command runs; a project with none places everything on the host
    # @param host_rule [Dev::HostRule] whether an image's work runs here
    sig do
      params(
        ui: Dev::Cli::Ui,
        project_root: Pathname,
        images: Dev::ProjectImages,
        container_client: T.nilable(Dev::BuildContainer),
        inside_container: T::Boolean,
        host_rule: Dev::HostRule,
        github_token: Dev::ContainerGithubToken,
      ).void
    end
    def initialize(ui:, project_root:, images: Dev::ProjectImages.new(root: project_root), container_client: nil,
                   inside_container: ContainerContext.inside?, host_rule: Dev::HostRule.new,
                   github_token: Dev::ContainerGithubToken.new)
      @ui = ui
      @images = images
      @project_root = project_root
      @container_client = container_client
      @inside_container = inside_container
      @host_rule = host_rule
      @github_token = github_token
    end

    # Hand the process over to the command: exec-replace, the right shape
    # for a leaf command (TTY and signal passthrough, no double process
    # tree). Never returns in production.
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
      if placement == ProjectImages::HOST
        ensure_shadowenv_provisioned!
        if cmd.repl
          run_bare(shell_command, wait:)
        else
          run_with_status_footer(shell_command, wait:)
        end
      else
        run_in_container(T.cast(placement, ProjectImages::Image), shell_command, wait:)
      end
    end

    # Where the command runs: here, or in a container of its image. Here
    # when the command's environment is the host, when this host was
    # provisioned from the image (the host rule), or when we are already
    # inside a container of it; the image otherwise. Inside a container
    # that is not the image's, the work is refused.
    #
    # @param cmd [ProjectCommand]
    # @return [ProjectImages::Placement]
    # @raise [ProjectImages::UnknownImageError, ProjectImages::AmbiguousEnvironmentImageError]
    # @raise [HostRule::ContainerDriftError] inside a container that is not the lock's image
    sig { params(cmd: ProjectCommand).returns(ProjectImages::Placement) }
    def placement(cmd)
      placement = @images.for(cmd)
      return placement if placement == ProjectImages::HOST

      image = T.cast(placement, ProjectImages::Image)
      if @inside_container
        @host_rule.assert_container_is!(image)
        return ProjectImages::HOST
      end

      @host_rule.native?(image) ? ProjectImages::HOST : image
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

    # @param image [ProjectImages::Image] the command's environment
    # @param shell_command [String]
    # @param wait [Boolean]
    # @return [void]
    sig { params(image: ProjectImages::Image, shell_command: String, wait: T::Boolean).void }
    def run_in_container(image, shell_command, wait:)
      client = container_client
      image_tag = @images.ensure!(image, client:, publish: publish_image?)
      invocation = container_command(image, image_tag, shell_command)

      Dir.chdir(@project_root)
      # The child argv carries the engine's argv prefix and names the
      # injected variables; their values and the engine's env (e.g. the
      # colima DOCKER_HOST) ride the spawn env, same as child_env locally —
      # nothing secret on an argv (dev#317).
      run_child([client.engine.env.merge(invocation.env), *invocation.argv], wait:)
    end

    # The engine-injected docker operations, constructed at this seam (the
    # composition point plans#26 names): the engine resolves per invoking
    # user, lazily, so commands that never touch a container never read the
    # engine record.
    #
    # @return [Dev::BuildContainer]
    sig { returns(Dev::BuildContainer) }
    def container_client
      @container_client ||= Dev::BuildContainer.new(engine: Dev::ContainerEngine.resolve)
    end

    # docker argv for a containerized command: a `docker exec` into the reused
    # long-lived container when the image persists (its writable layer keeps
    # the build tool's incremental state across commands), else a one-shot
    # `docker run --rm`. One persistent container per (image, workspace).
    #
    # @param image         [ProjectImages::Image] the command's environment
    # @param image_tag     [String]
    # @param shell_command [String]
    # @return [Dev::BuildContainer::Invocation]
    sig { params(image: ProjectImages::Image, image_tag: String, shell_command: String).returns(Dev::BuildContainer::Invocation) }
    def container_command(image, image_tag, shell_command)
      # Volumes mount as declared. Nothing of the host's data root is
      # resolved into them: the container owns its own (ADR-0008).
      volumes = image.volumes

      if image.persist
        container = container_client.ensure_service!(
          image_tag, project_root: @project_root, volumes: volumes,
        )
        container_client.docker_exec_command(
          container, shell_cmd: shell_command, env: resolve_run_env(image),
        )
      else
        container_client.docker_run_command(
          image_tag,
          project_root: @project_root,
          shell_cmd: shell_command,
          volumes: volumes,
          env: resolve_run_env(image),
        )
      end
    end

    # Resolve the image's `run_env` for `docker run -e`: best-effort and
    # non-interactive (Dev::Credentials.resolve_run_env), so a missing
    # runtime secret never blocks a command that doesn't need it; then the
    # host's gh token as GH_TOKEN unless the run_env named one.
    #
    # @param image [ProjectImages::Image]
    # @return [Hash{String => String}]
    sig { params(image: ProjectImages::Image).returns(T::Hash[String, String]) }
    def resolve_run_env(image)
      @github_token.merge_into(Dev::Credentials.resolve_run_env(image.run_env))
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
      return if @inside_container

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
