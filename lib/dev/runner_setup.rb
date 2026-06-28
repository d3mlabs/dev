# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"

module Dev
  # Registers the current host as a repo's self-hosted GitHub Actions runner.
  #
  # This is the one shared implementation behind `dev runner-setup`; repos opt in
  # by declaring a `runner:` block in dev.yml (see Dev::RunnerSetupConfig) instead
  # of vendoring a per-repo setup script. With `gh` already authenticated, there's
  # no manual "copy a registration token from the web UI" step — we mint one via
  # the API. Idempotent: re-running reconfigures the existing runner (--replace).
  #
  # It installs a systemd service and touches the host filesystem + network, so it
  # runs on the host (a built-in command), never inside a build container.
  #
  # The CLI boundary (gh / curl / tar / config.sh / svc.sh) is isolated behind an
  # injectable Executor so the orchestration can be exercised in tests without
  # real side effects.
  class RunnerSetup
    class Error < StandardError; end

    # Pinned runner version; override per-repo via dev.yml `runner.version`.
    DEFAULT_VERSION = "2.335.1"

    # Thin wrapper over the external CLIs RunnerSetup drives. Tests inject a fake.
    class Executor
      # @return [Array(String, String, Boolean)] stdout, stderr, success?
      def capture(*argv)
        out, err, status = Open3.capture3(*argv)
        [out, err, status.success?]
      rescue Errno::ENOENT => e
        ["", e.message, false]
      end

      # @return [Boolean] whether the command exited 0
      def system(*argv, chdir: nil)
        opts = chdir ? { chdir: chdir } : {}
        Kernel.system(*argv, **opts)
      end
    end

    # @param config [Dev::RunnerSetupConfig] the repo's runner declaration
    # @param repo [String, nil] "owner/repo" override; defaults to `gh repo view`
    # @param executor [Executor] CLI boundary (injectable for tests)
    # @param out [IO] progress stream
    def initialize(config:, repo: nil, executor: Executor.new, out: $stdout)
      @config = config
      @repo_override = repo
      @exec = executor
      @out = out
    end

    # Run the full setup: preflight, download, register, install the service.
    #
    # @return [void]
    # @raise [Error] on any preflight or step failure
    def run
      dir = resolve_dir
      guard_ext4!(dir)
      ensure_gh_authenticated!

      repo = resolve_repo
      url = "https://github.com/#{repo}"
      name = resolve_name
      version = resolve_version

      @out.puts ">>> Setting up runner '#{name}' for #{repo} (labels: #{@config.labels})"
      download_runner(dir, version)
      token = mint_registration_token(repo)
      configure_runner(dir: dir, url: url, token: token, name: name)
      install_service(dir)
      @out.puts ">>> Runner '#{name}' is registered and running. " \
                "It should show Idle on the GitHub Runners page."
    end

    # Absolute install dir. Defaults to ~/actions-runner-<first label> so multiple
    # repos can register distinct runners on the same box without colliding.
    #
    # @return [String]
    def resolve_dir
      File.expand_path(@config.dir || "~/actions-runner-#{default_dir_suffix}")
    end

    # @return [String]
    def resolve_name
      @config.name || Socket.gethostname
    end

    # @return [String]
    def resolve_version
      @config.version || DEFAULT_VERSION
    end

    # The argv `config.sh` is invoked with (relative to the runner dir). Pure, so
    # the registration contract is testable without touching the system.
    #
    # @return [Array<String>]
    def config_argv(url:, token:, name:)
      [
        "./config.sh",
        "--url", url,
        "--token", token,
        "--labels", @config.labels,
        "--name", name,
        "--unattended",
        "--replace",
      ]
    end

    private

    # The Windows drive can't set Unix perms, so an install under /mnt/c spams
    # 'Cannot utime' and leaves a broken runner. Force an ext4 path.
    #
    # @param dir [String] resolved install dir
    # @raise [Error] when dir is on a Windows mount
    def guard_ext4!(dir)
      return unless dir.start_with?("/mnt/")

      raise Error, "runner dir (#{dir}) is on a Windows drive. " \
                   "Use an ext4 path like $HOME (override runner.dir in dev.yml)."
    end

    # @raise [Error] when gh is missing or unauthenticated
    def ensure_gh_authenticated!
      _out, _err, ok = @exec.capture("gh", "auth", "status")
      return if ok

      raise Error, "gh is not authenticated — run: gh auth login"
    end

    # @return [String] "owner/repo"
    # @raise [Error] when the repo can't be resolved
    def resolve_repo
      return @repo_override if @repo_override

      out, err, ok = @exec.capture("gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
      repo = out.strip
      raise Error, "could not resolve the repo via gh: #{err.strip}" if !ok || repo.empty?

      repo
    end

    # Download + extract the actions-runner, skipping when already present.
    #
    # @param dir [String] install dir
    # @param version [String] runner version
    # @raise [Error] on download/extract failure
    def download_runner(dir, version)
      FileUtils.mkdir_p(dir)
      if File.executable?(File.join(dir, "config.sh"))
        @out.puts ">>> actions-runner already present in #{dir}."
        return
      end

      tarball = "actions-runner-linux-x64-#{version}.tar.gz"
      url = "https://github.com/actions/runner/releases/download/v#{version}/#{tarball}"
      @out.puts ">>> Downloading actions-runner #{version} ..."
      raise Error, "failed to download #{url}" unless @exec.system("curl", "-fsSL", "-o", tarball, url, chdir: dir)
      raise Error, "failed to extract #{tarball}" unless @exec.system("tar", "xzf", tarball, chdir: dir)

      FileUtils.rm_f(File.join(dir, tarball))
    end

    # @param repo [String] "owner/repo"
    # @return [String] a fresh registration token
    # @raise [Error] when the token can't be minted
    def mint_registration_token(repo)
      @out.puts ">>> Minting a registration token ..."
      out, err, ok = @exec.capture(
        "gh", "api", "-X", "POST",
        "repos/#{repo}/actions/runners/registration-token",
        "--jq", ".token"
      )
      token = out.strip
      raise Error, "failed to mint a registration token: #{err.strip}" if !ok || token.empty?

      token
    end

    # @raise [Error] when config.sh fails
    def configure_runner(dir:, url:, token:, name:)
      @out.puts ">>> Configuring the runner (--replace) ..."
      return if @exec.system(*config_argv(url: url, token: token, name: name), chdir: dir)

      raise Error, "config.sh failed to register the runner"
    end

    # svc.sh manages the systemd unit and needs root (interactive sudo is fine).
    # `svc.sh start` already echoes the unit status, so there's no separate status
    # call (a redundant one prints the same service twice).
    #
    # @param dir [String] install dir
    # @raise [Error] when the service can't be installed or started
    def install_service(dir)
      @out.puts ">>> Installing + starting the runner service ..."
      raise Error, "svc.sh install failed" unless @exec.system("sudo", "./svc.sh", "install", chdir: dir)
      raise Error, "svc.sh start failed" unless @exec.system("sudo", "./svc.sh", "start", chdir: dir)
    end

    # First label, sanitized for use in a directory name.
    #
    # @return [String]
    def default_dir_suffix
      first = @config.labels.split(",").first.to_s
      sanitized = first.gsub(/[^A-Za-z0-9_.-]/, "-")
      sanitized.empty? ? "default" : sanitized
    end
  end
end
