# typed: strict
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "stringio"

module Dev
  # Registers the current host as a self-hosted GitHub Actions runner — scoped
  # to a repo by default, or to the whole org (`org: true`) so one runner
  # serves every repo without per-repo registration.
  #
  # This is the one shared implementation behind `dev runner register`; repos opt in
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
  # The enrollment may belong to another OS user (`as_user:`, the Linux
  # runner user of dev#310): then every step that touches its files — the
  # dir, the download, `config.sh` — runs as that user through `sudo -u`,
  # the dir defaults under that user's home, and the unit is installed for
  # it (`svc.sh install <user>`). What needs the operator stays the
  # operator's: `gh` mints the tokens (admin), `sudo` installs the unit
  # (root). Without `as_user:` the enrollment is the invoking user's own,
  # as `config.sh`/`svc.sh` assume.
  #
  # The CLI boundary (gh / curl / tar / config.sh / svc.sh) is isolated behind an
  # injectable Executor so the orchestration can be exercised in tests without
  # real side effects.
  class RunnerSetup
    extend T::Sig

    class Error < StandardError; end

    # Pinned runner version; override per-repo via dev.yml `runner.version`.
    DEFAULT_VERSION = "2.335.1"

    # What config.sh says when the registration it would remove is not on
    # the server — superseded by `--replace`, or already removed. The
    # admin-flow delete answers 404; the legacy flow prints "Does not
    # exist" and exits 0 on its own.
    GONE_PATTERN = T.let(/404|not found|does not exist/i, Regexp)

    # The files that make a runner dir an enrollment: config.sh writes the
    # first three, svc.sh the fourth. Without them the dir is a download.
    ENROLLMENT_FILES = T.let(%w[.runner .credentials .credentials_rsaparams .service].freeze, T::Array[String])

    # Thin wrapper over the external CLIs RunnerSetup drives. Tests inject a fake.
    class Executor
      extend T::Sig

      # @param chdir [String, nil] the directory to run in (the runner
      #   scripts are invoked relative to their install dir)
      # @param stdin [String, nil] what the command reads on stdin (a
      #   secret rides here, never argv)
      # @return [Array(String, String, Boolean)] stdout, stderr, success?
      sig { params(argv: String, chdir: T.nilable(String), stdin: T.nilable(String)).returns([String, String, T::Boolean]) }
      def capture(*argv, chdir: nil, stdin: nil)
        opts = {}
        opts[:chdir] = chdir if chdir
        opts[:stdin_data] = stdin if stdin
        out, err, status = Open3.capture3(*T.unsafe(argv), **opts)
        [out, err, status.success?]
      rescue Errno::ENOENT => e
        ["", e.message, false]
      end

      # @return [Boolean, nil] whether the command exited 0 (nil when it
      #   could not be spawned)
      sig { params(argv: String, chdir: T.nilable(String)).returns(T.nilable(T::Boolean)) }
      def system(*argv, chdir: nil)
        opts = chdir ? { chdir: chdir } : {}
        Kernel.system(*T.unsafe(argv), **opts)
      end
    end

    # @param config [Dev::RunnerSetupConfig] the repo's runner declaration
    # @param repo [String, nil] "owner/repo" override; defaults to `gh repo view`
    # @param org [Boolean] register at the org scope (the repo's owner) instead
    #   of the repo scope, so the runner serves every repo in the org
    # @param executor [#capture, #system] CLI boundary (default: Executor;
    #   injectable for tests)
    # @param out [IO, StringIO] progress stream
    # @param host_platform [String] actions-runner release platform slug for this
    #   host (e.g. "linux-x64", "osx-arm64"); defaults to detection. Drives both
    #   the tarball choice and the service-install shape (systemd vs LaunchAgent).
    # @param as_user [String, nil] the OS user the enrollment belongs to and the
    #   service runs as, when not the invoking user (dev#310)
    # @param home [String, nil] the home the default dir lives under: the
    #   enrollment owner's (defaults to the invoking user's)
    # @param path [String, nil] the PATH the owner's commands run on
    #   (RunnerUser#path); config.sh records it and the runner hands it to
    #   every job. nil leaves sudo's.
    sig do
      params(
        config: Dev::RunnerSetupConfig,
        repo: T.nilable(String),
        org: T::Boolean,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        host_platform: String,
        as_user: T.nilable(String),
        home: T.nilable(String),
        path: T.nilable(String),
      ).void
    end
    def initialize(config:, repo: nil, org: false, executor: Executor.new, out: $stdout,
                   host_platform: self.class.detect_host_platform, as_user: nil, home: nil, path: nil)
      @config = config
      @repo_override = repo
      @org = org
      @exec = executor
      @out = out
      @host_platform = host_platform
      @as_user = as_user
      @home = T.let(home || Dir.home, String)
      @path = path
    end

    class << self
      extend T::Sig

      # The actions-runner release platform slug for the current host (GitHub
      # names macOS "osx").
      #
      # @return [String]
      sig { returns(String) }
      def detect_host_platform
        os = RUBY_PLATFORM.include?("darwin") ? "osx" : "linux"
        arch = RUBY_PLATFORM.match?(/arm64|aarch64/) ? "arm64" : "x64"
        "#{os}-#{arch}"
      end

      # The enclosing checkout's repo as GitHub spells it — the one `gh repo
      # view` seam, shared by the setup's own scope resolution and by `dev
      # runner register`'s label derivation (the label *is* this name).
      #
      # @param executor [#capture] CLI boundary
      # @return [String] "owner/repo"
      # @raise [Error] when gh cannot resolve the checkout
      sig { params(executor: T.untyped).returns(String) }
      def current_repo(executor: Executor.new)
        out, err, ok = executor.capture("gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
        repo = out.strip
        raise Error, "could not resolve the repo via gh: #{err.strip}" if !ok || repo.empty?

        repo
      end

      # Mint a runner token via the API. `kind` is "registration-token" (to
      # add) or "remove-token" (to deregister); the endpoint follows the
      # scope's shape (repos/... for "owner/repo", orgs/... for a bare org).
      # The one token seam, shared with RunnerTeardown's deregistration.
      #
      # @param scope [String] "owner/repo" or "owner"
      # @param kind [String]
      # @param executor [#capture] CLI boundary
      # @return [String]
      # @raise [Error] when the token can't be minted
      sig { params(scope: String, kind: String, executor: T.untyped).returns(String) }
      def mint_token(scope, kind, executor: Executor.new)
        base = scope.include?("/") ? "repos/#{scope}" : "orgs/#{scope}"
        out, err, ok = executor.capture(
          "gh", "api", "-X", "POST",
          "#{base}/actions/runners/#{kind}",
          "--jq", ".token"
        )
        token = out.strip
        raise Error, "failed to mint a #{kind}: #{err.strip}" if !ok || token.empty?

        token
      end

      # Deregister the runner configured in `dir` — `config.sh remove` with
      # a remove token minted at `scope`, the enrollment's *own* scope —
      # then clear the enrollment files (config.sh removes its own on
      # success; after a gone registration they are stale and would make
      # the next `config.sh` refuse). A registration the server no longer
      # has counts as removed: that is the state `--replace` leaves an
      # older dir in, and the files are what still need clearing. The one
      # deregistration seam, shared by re-registration and RunnerTeardown.
      #
      # @param dir [String] the runner install dir
      # @param scope [String] the scope the registration is under
      # @param executor [#capture, #system] CLI boundary
      # @param out [IO, StringIO] config.sh's output is echoed here
      # @param as_user [String, nil] the enrollment's owner when not the
      #   invoking user: config.sh and the file removal run as it
      # @return [String] what happened, in words ("registration removed" /
      #   "registration already gone from the server")
      # @raise [Error] when the token can't be minted or config.sh fails
      #   for another reason; the files are left as they were
      sig do
        params(dir: String, scope: String, executor: T.untyped, out: T.any(IO, StringIO), as_user: T.nilable(String))
          .returns(String)
      end
      def remove_registration(dir, scope, executor: Executor.new, out: $stdout, as_user: nil)
        token = mint_token(scope, "remove-token", executor: executor)
        stdout, stderr, ok = executor.capture(*as_user_argv(as_user, ["./config.sh", "remove", "--token", token]), chdir: dir)
        out.print(stdout) unless stdout.empty?
        output = "#{stdout}\n#{stderr}".strip
        unless ok || output.match?(GONE_PATTERN)
          raise Error, "config.sh remove failed in #{dir} (try ./config.sh remove manually there): #{output}"
        end

        remove_files(ENROLLMENT_FILES, dir: dir, executor: executor, as_user: as_user)
        ok ? "registration removed" : "registration already gone from the server"
      end

      # A command as the enrollment's owner when that is another user, the
      # command itself otherwise.
      #
      # @param as_user [String, nil]
      # @param cmd [Array<String>]
      # @return [Array<String>]
      sig { params(as_user: T.nilable(String), cmd: T::Array[String], path: T.nilable(String)).returns(T::Array[String]) }
      def as_user_argv(as_user, cmd, path: nil)
        return cmd unless as_user

        env = path ? ["env", "PATH=#{path}"] : []
        ["sudo", "-u", as_user, "-H"] + env + cmd
      end

      # Remove files in a runner dir: with the operator's own hands for its
      # own enrollment, as the owner (through sudo) for another user's.
      #
      # @param files [Array<String>] names relative to dir
      # @param dir [String]
      # @param executor [#system]
      # @param as_user [String, nil]
      # @return [void]
      sig { params(files: T::Array[String], dir: String, executor: T.untyped, as_user: T.nilable(String)).void }
      def remove_files(files, dir:, executor:, as_user:)
        if as_user
          executor.system(*as_user_argv(as_user, ["rm", "-f", *files]), chdir: dir)
        else
          files.each { |file| FileUtils.rm_f(File.join(dir, file)) }
        end
      end

      # The argv that drives svc.sh for one action, relative to the runner
      # dir. On Linux that's a systemd unit and needs root (interactive
      # sudo is fine); on macOS it's a per-user LaunchAgent and svc.sh must
      # run as the user — under sudo it would install a root agent that
      # never loads into the user's launchd session. Shared with
      # RunnerTeardown so install and uninstall agree on the OS split.
      #
      # @param action [String] svc.sh subcommand
      # @param host_platform [String] actions-runner platform slug
      # @return [Array<String>]
      sig { params(action: String, host_platform: String).returns(T::Array[String]) }
      def service_argv(action, host_platform:)
        host_platform.start_with?("osx") ? ["./svc.sh", action] : ["sudo", "./svc.sh", action]
      end
    end

    # Run the full setup: preflight, download, register, install the service.
    #
    # @return [void]
    # @raise [Error] on any preflight or step failure
    sig { void }
    def run
      dir = resolve_dir
      guard_ext4!(dir)
      ensure_gh_authenticated!

      scope = resolve_scope
      url = "https://github.com/#{scope}"
      name = resolve_name
      version = resolve_version

      @out.puts ">>> Setting up runner '#{name}' for #{scope}#{@org ? " (org-wide)" : ""}" \
                "#{@as_user ? " as #{@as_user}" : ""} (labels: #{@config.labels})"
      download_runner(dir, version)
      remove_existing_config(dir, scope)
      token = mint_registration_token(scope)
      configure_runner(dir: dir, url: url, token: token, name: name)
      install_service(dir)
      @out.puts ">>> Runner '#{name}' is registered and running. " \
                "It should show Idle on the GitHub Runners page."
    end

    # Absolute install dir. Defaults to <home>/actions-runner-<first label> —
    # the enrollment owner's home — so multiple repos can register distinct
    # runners on the same box without colliding.
    #
    # @return [String]
    sig { returns(String) }
    def resolve_dir
      File.expand_path(@config.dir || File.join(@home, "actions-runner-#{default_dir_suffix}"))
    end

    # @return [String]
    sig { returns(String) }
    def resolve_name
      @config.name || Socket.gethostname
    end

    # @return [String]
    sig { returns(String) }
    def resolve_version
      @config.version || DEFAULT_VERSION
    end

    # The registration scope: "owner/repo" (repo mode) or "owner" (org mode —
    # the org is the resolved repo's owner, so `--org` needs no extra flag).
    # Public so register can look for an existing enrollment at the target
    # scope before deciding between the amend path and a fresh enrollment.
    #
    # @return [String]
    # @raise [Error] when the repo can't be resolved
    sig { returns(String) }
    def resolve_scope
      repo = resolve_repo
      @org ? repo.split("/").fetch(0) : repo
    end

    # The argv `config.sh` is invoked with (relative to the runner dir). Pure, so
    # the registration contract is testable without touching the system.
    #
    # @return [Array<String>]
    sig { params(url: String, token: String, name: String).returns(T::Array[String]) }
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
    sig { params(dir: String).void }
    def guard_ext4!(dir)
      return unless dir.start_with?("/mnt/")

      raise Error, "runner dir (#{dir}) is on a Windows drive. " \
                   "Use an ext4 path like $HOME (override runner.dir in dev.yml)."
    end

    # @raise [Error] when gh is missing or unauthenticated
    sig { void }
    def ensure_gh_authenticated!
      _out, _err, ok = @exec.capture("gh", "auth", "status")
      return if ok

      raise Error, "gh is not authenticated — run: gh auth login"
    end

    # @return [String] "owner/repo"
    # @raise [Error] when the repo can't be resolved
    sig { returns(String) }
    def resolve_repo
      @repo_override || self.class.current_repo(executor: @exec)
    end

    # Download + extract the actions-runner, skipping when already present.
    #
    # @param dir [String] install dir
    # @param version [String] runner version
    # @raise [Error] on download/extract failure
    sig { params(dir: String, version: String).void }
    def download_runner(dir, version)
      make_dir(dir)
      if File.executable?(File.join(dir, "config.sh"))
        @out.puts ">>> actions-runner already present in #{dir}."
        return
      end

      tarball = "actions-runner-#{@host_platform}-#{version}.tar.gz"
      url = "https://github.com/actions/runner/releases/download/v#{version}/#{tarball}"
      @out.puts ">>> Downloading actions-runner #{version} ..."
      raise Error, "failed to download #{url}" unless @exec.system(*as_user_argv("curl", "-fsSL", "-o", tarball, url), chdir: dir)
      raise Error, "failed to extract #{tarball}" unless @exec.system(*as_user_argv("tar", "xzf", tarball), chdir: dir)

      self.class.remove_files([tarball], dir: dir, executor: @exec, as_user: @as_user)
    end

    # The runner dir: made with the operator's own hands for its own
    # enrollment, as the owner for another user's (whose home the operator
    # cannot write).
    #
    # @param dir [String]
    # @return [void]
    # @raise [Error] when the dir can't be made as the owner
    sig { params(dir: String).void }
    def make_dir(dir)
      if @as_user
        raise Error, "could not create #{dir} as #{@as_user}" unless @exec.system(*as_user_argv("mkdir", "-p", dir))
      else
        FileUtils.mkdir_p(dir)
      end
    end

    # @param cmd [Array<String>]
    # @return [Array<String>]
    sig { params(cmd: String).returns(T::Array[String]) }
    def as_user_argv(*cmd)
      self.class.as_user_argv(@as_user, cmd, path: @path)
    end

    # Make re-runs idempotent. config.sh refuses to configure a dir that already
    # holds a runner (`.runner`), and `--replace` only resolves a *server-side*
    # same-name collision — not the local guard — so an existing config must be
    # removed first. The remove token is minted at the scope the runner is
    # *currently* registered under (read from its .runner file), not the target
    # scope — that's what makes a repo→org migration a plain re-run. A
    # registration the server has already lost is removed all the same
    # (see .remove_registration). No-op on a fresh dir.
    #
    # @param dir [String] install dir
    # @param scope [String] the target scope ("owner/repo" or "owner"), used as
    #   a fallback when the existing registration's scope can't be read
    # @raise [Error] when the stale config can't be removed
    sig { params(dir: String, scope: String).void }
    def remove_existing_config(dir, scope)
      return unless File.exist?(File.join(dir, ".runner"))

      existing_scope = existing_registration_scope(dir) || scope
      @out.puts ">>> Existing runner config found (#{existing_scope}); removing it before reconfiguring ..."
      uninstall_existing_service(dir)
      outcome = self.class.remove_registration(dir, existing_scope, executor: @exec, out: @out, as_user: @as_user)
      @out.puts ">>> Existing config: #{outcome}."
    end

    # config.sh remove refuses while the service unit is installed ("Uninstall
    # service first"), so stop + uninstall it before deregistering; install_service
    # reinstalls it after the new registration. Best-effort (no raise): a dir
    # whose service was never installed, or already removed, has nothing to undo.
    #
    # @param dir [String] install dir
    sig { params(dir: String).void }
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
    sig { params(dir: String).returns(T.nilable(String)) }
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
    sig { params(scope: String).returns(String) }
    def mint_registration_token(scope)
      @out.puts ">>> Minting a registration token ..."
      mint_token(scope, "registration-token")
    end

    # @param scope [String] "owner/repo" or "owner"
    # @param kind [String] "registration-token" or "remove-token"
    # @return [String]
    # @raise [Error] when the token can't be minted
    sig { params(scope: String, kind: String).returns(String) }
    def mint_token(scope, kind)
      self.class.mint_token(scope, kind, executor: @exec)
    end

    # @raise [Error] when config.sh fails
    sig { params(dir: String, url: String, token: String, name: String).void }
    def configure_runner(dir:, url:, token:, name:)
      @out.puts ">>> Configuring the runner (--replace) ..."
      argv = self.class.as_user_argv(@as_user, config_argv(url: url, token: token, name: name), path: @path)
      return if @exec.system(*argv, chdir: dir)

      raise Error, "config.sh failed to register the runner"
    end

    # svc.sh installs and starts the service unit (see .service_argv for the
    # OS split); for another user's enrollment the unit runs as that user
    # (`svc.sh install <user>` sets the unit's User=). `svc.sh start`
    # already echoes the unit status, so there's no separate status call
    # (a redundant one prints the same service twice).
    #
    # @param dir [String] install dir
    # @raise [Error] when the service can't be installed or started
    sig { params(dir: String).void }
    def install_service(dir)
      @out.puts ">>> Installing + starting the runner service#{@as_user ? " as #{@as_user}" : ""} ..."
      install = service_argv("install")
      as_user = @as_user
      install << as_user if as_user
      raise Error, "svc.sh install failed" unless @exec.system(*install, chdir: dir)
      raise Error, "svc.sh start failed" unless @exec.system(*service_argv("start"), chdir: dir)
    end

    # @param action [String] svc.sh subcommand
    # @return [Array<String>]
    sig { params(action: String).returns(T::Array[String]) }
    def service_argv(action)
      self.class.service_argv(action, host_platform: @host_platform)
    end

    # First label, sanitized for use in a directory name.
    #
    # @return [String]
    sig { returns(String) }
    def default_dir_suffix
      first = @config.labels.split(",").first.to_s
      sanitized = first.gsub(/[^A-Za-z0-9_.-]/, "-")
      sanitized.empty? ? "default" : sanitized
    end
  end
end
