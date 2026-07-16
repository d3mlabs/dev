# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"

module Dev
  # Registers the current host as a self-hosted GitHub Actions runner — scoped
  # to a repo by default, or to the whole org (`org: true`) so one runner
  # serves every repo without per-repo registration.
  #
  # This is the one shared implementation behind `dev runner-setup`; repos opt in
  # by declaring a `runner:` block in dev.yml (see Dev::RunnerSetupConfig) instead
  # of vendoring a per-repo setup script. With `gh` already authenticated, there's
  # no manual "copy a registration token from the web UI" step — we mint one via
  # the API (org scope needs the admin:org gh scope). Idempotent: re-running
  # reconfigures the existing runner (--replace), including across scopes — a
  # repo-scoped runner re-registered with `org: true` is deregistered at its old
  # scope first (read back from the runner's own .runner file).
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
    # @param org [Boolean] register at the org scope (the repo's owner) instead
    #   of the repo scope, so the runner serves every repo in the org
    # @param executor [Executor] CLI boundary (injectable for tests)
    # @param out [IO] progress stream
    # @param host_platform [String] actions-runner release platform slug for this
    #   host (e.g. "linux-x64", "osx-arm64"); defaults to detection. Drives both
    #   the tarball choice and the service-install shape (systemd vs LaunchAgent).
    def initialize(config:, repo: nil, org: false, executor: Executor.new, out: $stdout,
                   host_platform: self.class.detect_host_platform)
      @config = config
      @repo_override = repo
      @org = org
      @exec = executor
      @out = out
      @host_platform = host_platform
    end

    # The actions-runner release platform slug for the current host (GitHub
    # names macOS "osx").
    #
    # @return [String]
    def self.detect_host_platform
      os = RUBY_PLATFORM.include?("darwin") ? "osx" : "linux"
      arch = RUBY_PLATFORM.match?(/arm64|aarch64/) ? "arm64" : "x64"
      "#{os}-#{arch}"
    end

    # Run the full setup: preflight, download, register, install the service.
    #
    # @return [void]
    # @raise [Error] on any preflight or step failure
    def run
      dir = resolve_dir
      guard_ext4!(dir)
      ensure_gh_authenticated!

      scope = resolve_scope
      url = "https://github.com/#{scope}"
      name = resolve_name
      version = resolve_version

      @out.puts ">>> Setting up runner '#{name}' for #{scope}#{@org ? " (org-wide)" : ""} " \
                "(labels: #{@config.labels})"
      download_runner(dir, version)
      remove_existing_config(dir, scope)
      token = mint_registration_token(scope)
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

    # The registration scope: "owner/repo" (repo mode) or "owner" (org mode —
    # the org is the resolved repo's owner, so `--org` needs no extra flag).
    #
    # @return [String]
    # @raise [Error] when the repo can't be resolved
    def resolve_scope
      repo = resolve_repo
      @org ? repo.split("/").fetch(0) : repo
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

      tarball = "actions-runner-#{@host_platform}-#{version}.tar.gz"
      url = "https://github.com/actions/runner/releases/download/v#{version}/#{tarball}"
      @out.puts ">>> Downloading actions-runner #{version} ..."
      raise Error, "failed to download #{url}" unless @exec.system("curl", "-fsSL", "-o", tarball, url, chdir: dir)
      raise Error, "failed to extract #{tarball}" unless @exec.system("tar", "xzf", tarball, chdir: dir)

      FileUtils.rm_f(File.join(dir, tarball))
    end

    # Make re-runs idempotent. config.sh refuses to configure a dir that already
    # holds a runner (`.runner`), and `--replace` only resolves a *server-side*
    # same-name collision — not the local guard — so an existing config must be
    # removed first. The remove token is minted at the scope the runner is
    # *currently* registered under (read from its .runner file), not the target
    # scope — that's what makes a repo→org migration a plain re-run. No-op on a
    # fresh dir.
    #
    # @param dir [String] install dir
    # @param scope [String] the target scope ("owner/repo" or "owner"), used as
    #   a fallback when the existing registration's scope can't be read
    # @raise [Error] when the stale config can't be removed
    def remove_existing_config(dir, scope)
      return unless File.exist?(File.join(dir, ".runner"))

      existing_scope = existing_registration_scope(dir) || scope
      @out.puts ">>> Existing runner config found (#{existing_scope}); removing it before reconfiguring ..."
      uninstall_existing_service(dir)
      token = mint_token(existing_scope, "remove-token")
      return if @exec.system("./config.sh", "remove", "--token", token, chdir: dir)

      raise Error, "failed to remove the existing runner config (try ./config.sh remove manually in #{dir})"
    end

    # config.sh remove refuses while the service unit is installed ("Uninstall
    # service first"), so stop + uninstall it before deregistering; install_service
    # reinstalls it after the new registration. Best-effort (no raise): a dir
    # whose service was never installed, or already removed, has nothing to undo.
    #
    # @param dir [String] install dir
    def uninstall_existing_service(dir)
      return unless File.exist?(File.join(dir, ".service"))

      @out.puts ">>> Stopping + uninstalling the existing runner service ..."
      @exec.system(*service_argv("stop"), chdir: dir)
      @exec.system(*service_argv("uninstall"), chdir: dir)
    end

    # The scope of the runner currently configured in dir, read from the
    # gitHubUrl config.sh wrote into .runner ("https://github.com/owner[/repo]").
    # config.sh writes the file with a UTF-8 BOM, so read with "bom|utf-8" or
    # JSON.parse chokes on the first byte. nil when the file can't be parsed,
    # so the caller can fall back.
    #
    # @param dir [String] install dir
    # @return [String, nil] "owner/repo" or "owner"
    def existing_registration_scope(dir)
      raw = File.read(File.join(dir, ".runner"), encoding: "bom|utf-8")
      url = JSON.parse(raw)["gitHubUrl"].to_s
      scope = url.sub(%r{\Ahttps://github\.com/}, "").chomp("/")
      scope.empty? || scope == url ? nil : scope
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # @param scope [String] "owner/repo" or "owner"
    # @return [String] a fresh registration token
    # @raise [Error] when the token can't be minted
    def mint_registration_token(scope)
      @out.puts ">>> Minting a registration token ..."
      mint_token(scope, "registration-token")
    end

    # Mint a runner token via the API. `kind` is "registration-token" (to add)
    # or "remove-token" (to deregister); the endpoint follows the scope's shape
    # (repos/... for "owner/repo", orgs/... for a bare org).
    #
    # @param scope [String] "owner/repo" or "owner"
    # @param kind [String]
    # @return [String]
    # @raise [Error] when the token can't be minted
    def mint_token(scope, kind)
      base = scope.include?("/") ? "repos/#{scope}" : "orgs/#{scope}"
      out, err, ok = @exec.capture(
        "gh", "api", "-X", "POST",
        "#{base}/actions/runners/#{kind}",
        "--jq", ".token"
      )
      token = out.strip
      raise Error, "failed to mint a #{kind}: #{err.strip}" if !ok || token.empty?

      token
    end

    # @raise [Error] when config.sh fails
    def configure_runner(dir:, url:, token:, name:)
      @out.puts ">>> Configuring the runner (--replace) ..."
      return if @exec.system(*config_argv(url: url, token: token, name: name), chdir: dir)

      raise Error, "config.sh failed to register the runner"
    end

    # svc.sh manages the service unit. On Linux that's a systemd unit and needs
    # root (interactive sudo is fine); on macOS it's a per-user LaunchAgent and
    # svc.sh must run as the user — under sudo it would install a root agent
    # that never loads into the user's launchd session. `svc.sh start` already
    # echoes the unit status, so there's no separate status call (a redundant
    # one prints the same service twice).
    #
    # @param dir [String] install dir
    # @raise [Error] when the service can't be installed or started
    def install_service(dir)
      @out.puts ">>> Installing + starting the runner service ..."
      raise Error, "svc.sh install failed" unless @exec.system(*service_argv("install"), chdir: dir)
      raise Error, "svc.sh start failed" unless @exec.system(*service_argv("start"), chdir: dir)
    end

    # @param action [String] svc.sh subcommand
    # @return [Array<String>]
    def service_argv(action)
      darwin? ? ["./svc.sh", action] : ["sudo", "./svc.sh", action]
    end

    # @return [Boolean]
    def darwin?
      @host_platform.start_with?("osx")
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
