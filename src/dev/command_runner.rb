# typed: strict
# frozen_string_literal: true

require "shellwords"

require "dev/cli/ui"
require "dev/command"

module Dev
  # Runs dev commands by exec-ing into the child process. Dev prints a colored
  # header (command name) and then replaces itself:
  #
  # - repl commands: exec directly (no footer, for interactive sessions)
  # - non-repl commands: exec into a shell wrapper that runs the command and
  #   prints ✓ Done / ✗ Failed based on exit code
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

    sig do
      params(
        ui: Dev::Cli::Ui,
        ruby_version: String,
        build_container: T.nilable(Dev::BuildContainerConfig),
        project_root: Pathname,
      ).void
    end
    def initialize(ui:, ruby_version:, build_container: nil, project_root: Dev.target_project_root)
      @ui = T.let(ui, Dev::Cli::Ui)
      @ruby_version = T.let(ruby_version, String)
      @build_container = T.let(build_container, T.nilable(Dev::BuildContainerConfig))
      @project_root = T.let(project_root, Pathname)
    end

    sig { params(cmd: ShellCommand, args: T::Array[String]).void }
    def run(cmd, args: [])
      shell_command = build_shell_command(cmd.run, args)
      @ui.print_header(shell_command)

      if use_container?(cmd)
        run_in_container(cmd, shell_command)
      else
        ensure_shadowenv_provisioned!
        if cmd.repl
          run_replace_process(shell_command)
        else
          run_exec_with_status(shell_command)
        end
      end
    end

    private

    sig { params(cmd: ShellCommand).returns(T::Boolean) }
    def use_container?(cmd)
      !@build_container.nil? && cmd.container
    end

    sig { params(_cmd: ShellCommand, shell_command: String).void }
    def run_in_container(_cmd, shell_command)
      require "build_container"
      config = T.must(@build_container)
      warn_if_under_provisioned!(config)
      image_tag = BuildContainer.ensure_image!(
        config,
        project_root: @project_root,
        push: false,
        build_args_provider: -> { resolve_build_args(config) },
      )
      docker_argv = BuildContainer.docker_run_command(
        image_tag,
        project_root: @project_root,
        shell_cmd: shell_command,
        volumes: config.volumes,
        env: resolve_run_env(config),
      )

      Dir.chdir(@project_root)
      Kernel.exec(*docker_argv)
    end

    # Preflight the Docker VM against the project's declared resources.
    #
    # Docker Desktop's VM size is a host-wide setting a project can't raise on
    # its own, so an under-provisioned VM can't be fixed here — but a silent
    # 8 GiB VM throttles UBT to a handful of parallel actions and turns a ~15min
    # build into hours. We surface that loudly with remediation instead. Purely
    # advisory: never blocks, and skips silently when Docker info is unavailable.
    #
    # @param config [Dev::BuildContainerConfig]
    sig { params(config: Dev::BuildContainerConfig).void }
    def warn_if_under_provisioned!(config)
      resources = config.resources
      return if resources.empty?

      host = BuildContainer.host_resources
      return if host.nil?

      available_memory_gb = Integer(host.fetch(:mem_bytes)) / (1024 * 1024 * 1024)
      shortfalls = resources.shortfalls(
        available_cpus: Integer(host.fetch(:cpus)),
        available_memory_gb: available_memory_gb,
      )
      return if shortfalls.empty?

      print_under_provisioned_warning(shortfalls)
    end

    sig { params(shortfalls: T::Array[String]).void }
    def print_under_provisioned_warning(shortfalls)
      $stderr.puts
      $stderr.puts "dev: ⚠ Docker VM is smaller than this project declares:"
      shortfalls.each { |line| $stderr.puts "dev:     #{line}" }
      $stderr.puts "dev: The build will run but parallelism (and speed) suffer."
      $stderr.puts "dev: Raise Docker Desktop → Settings → Resources, or set"
      $stderr.puts "dev:   \"Cpus\" / \"MemoryMiB\" in"
      $stderr.puts "dev:   ~/Library/Group Containers/group.com.docker/settings-store.json"
      $stderr.puts "dev:   and restart Docker."
      $stderr.puts
    end

    # Resolve docker build args declared in dev.yml from Dev::Credentials.
    # Only invoked when the image actually needs building. Normally `dev up`
    # has already prompted and stored these, so this resolves silently.
    #
    # @param config [Dev::BuildContainerConfig]
    # @return [Hash{String => String}]
    sig { params(config: Dev::BuildContainerConfig).returns(T::Hash[String, String]) }
    def resolve_build_args(config)
      require "dev/credentials"
      Dev::Credentials.resolve_build_args(config.build_args)
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

      require "dev/credentials"
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
    # set up before command execution. Currently hardcoded to Ruby + LLVM.
    # When a third toolchain appears, generalize into a registry pattern (see #21).
    sig { void }
    def ensure_shadowenv_provisioned!
      require "shadowenv_ruby"
      project_root = @project_root
      unless ShadowenvRuby.provisioned?(@ruby_version, project_root: project_root)
        ShadowenvRuby.setup!(ruby_version: @ruby_version, project_root: project_root)
      end

      ensure_llvm_provisioned!(project_root)
    end

    sig { params(project_root: Pathname).void }
    def ensure_llvm_provisioned!(project_root)
      require "shadowenv_llvm"
      return if ShadowenvLlvm.ci_or_linux?
      return unless ShadowenvLlvm.project_needs_llvm?(project_root)

      prefix = ShadowenvLlvm.detect_llvm_prefix
      return unless prefix
      return if ShadowenvLlvm.provisioned?(prefix, project_root: project_root)

      ShadowenvLlvm.setup!(project_root: project_root, llvm_prefix: prefix)
    end

    sig { params(shell_command: String).void }
    def run_replace_process(shell_command)
      Dir.chdir(@project_root)
      Kernel.exec(child_env, "shadowenv", "exec", "--", "sh", "-c", shell_command)
    end

    # Execs into a shell wrapper that runs the command, then prints a colored
    # success/failure footer based on the exit code.
    sig { params(shell_command: String).void }
    def run_exec_with_status(shell_command)
      Dir.chdir(@project_root)
      Kernel.exec(child_env, "shadowenv", "exec", "--", "sh", "-c", <<~SH)
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
  end
end
