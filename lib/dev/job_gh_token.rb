# typed: strict
# frozen_string_literal: true

require "dev/runner_setup"
require "dev/runner_user"
require "dev/ui"

module Dev
  # The gh credential a slot's jobs fetch with, on a host whose
  # enrollments are the operator's own — a Mac, where the runner service
  # is a per-user LaunchAgent and no runner user exists. The operator's
  # gh login lives in the login keychain, which a process spawned by
  # launchd cannot read: a job's `gh auth token` answers nothing, and the
  # `d3mlabs/dev/up` action stops there. So the credential is `GH_TOKEN`
  # in the runner's `.env` — the file the listener exports to every job —
  # holding a machine user's token, the same token the Linux rule hands
  # to the runner user's `gh auth login` (RunnerUser). gh reads the
  # variable before any stored login.
  #
  # Register ensures it for every slot it enrolls or amends: a slot
  # carrying the key is settled; one without is asked for the token once
  # per run (hidden input), the token checked through gh before anything
  # is written, then written and the service bounced, since the runner
  # reads `.env` at start. `dev runner status` names a slot without it as
  # drift. The Linux rule has no part in this: there the runner user's
  # own login is the credential, and `.env` carries no token.
  class JobGhToken
    extend T::Sig

    # No token to write: the Ui answered nothing (headless), the answer
    # was empty, or gh refused it. The message carries what to do by hand.
    class TokenRequiredError < RuntimeError; end

    # svc.sh refused to stop or start the service around the write.
    class ServiceRestartError < RuntimeError; end

    # The runner's own env file: the listener exports every line of it.
    ENV_FILE = ".env"

    # The variable gh reads before any stored login.
    KEY = "GH_TOKEN"

    # The record svc.sh writes at install: present means a service to bounce.
    SERVICE_FILE = ".service"

    # The token is the owner's to read, and nobody else's.
    MODE = 0o600

    class << self
      extend T::Sig

      # Whether a runner dir's `.env` carries the key.
      #
      # @param runner_dir [String]
      # @return [Boolean]
      sig { params(runner_dir: String).returns(T::Boolean) }
      def present?(runner_dir)
        env_file = File.join(runner_dir, ENV_FILE)
        File.file?(env_file) && File.read(env_file).each_line(chomp: true).any? { |line| token_line?(line) }
      end

      # @param line [String] one line of the runner's `.env`
      # @return [Boolean] whether it sets the key
      sig { params(line: String).returns(T::Boolean) }
      def token_line?(line)
        line.start_with?("#{KEY}=")
      end
    end

    # @param executor [#system, #capture] runs svc.sh and gh
    # @param host_platform [String] actions-runner platform slug; drives the svc.sh sudo split
    # @param ui [Ui] asks for the token, speaks the step
    sig { params(executor: T.untyped, host_platform: String, ui: Ui).void }
    def initialize(executor: RunnerSetup::Executor.new, host_platform: RunnerSetup.detect_host_platform, ui: NoUi.new)
      @exec = executor
      @host_platform = host_platform
      @ui = ui
      @token = T.let(nil, T.nilable(String))
    end

    # Make sure one slot's jobs have the credential: nothing when the dir
    # carries the key; else the token (asked once per run, checked through
    # gh) is appended to `.env`, the file made the owner's alone, and the
    # service bounced around the write.
    #
    # @param runner_dir [String]
    # @return [void]
    # @raise [TokenRequiredError]
    # @raise [ServiceRestartError]
    sig { params(runner_dir: String).void }
    def ensure!(runner_dir:)
      return if self.class.present?(runner_dir)

      token = obtain!(runner_dir)
      env_file = File.join(runner_dir, ENV_FILE)
      @ui.step("Giving the jobs of #{runner_dir} a gh credential (#{KEY} in #{ENV_FILE}: the keychain login is unreadable from the service)") do
        service!(runner_dir, "stop")
        kept = File.file?(env_file) ? File.read(env_file) : ""
        kept += "\n" unless kept.empty? || kept.end_with?("\n")
        File.write(env_file, "#{kept}#{KEY}=#{token}\n", perm: MODE)
        File.chmod(MODE, env_file)
        service!(runner_dir, "start")
      end
    end

    private

    # The token for this run: asked the first time, checked through gh
    # with the variable set as a job would see it, and held for the
    # family's other slots.
    #
    # @param runner_dir [String] the slot being asked for, named in the by-hand message
    # @return [String]
    # @raise [TokenRequiredError]
    sig { params(runner_dir: String).returns(String) }
    def obtain!(runner_dir)
      held = @token
      return held if held

      token = @ui.ask_secret(
        "The jobs of #{runner_dir} have no gh credential — the login in your keychain is unreadable from the " \
        "runner service, and every job on this host fetches with it. Paste the machine user's token (#{RunnerUser.token_hint})",
      ).to_s.strip
      raise TokenRequiredError, headless_message(runner_dir) if token.empty?

      _out, err, ok = @exec.capture("gh", "auth", "status", env: { KEY => token })
      unless ok
        reason = err.lines.map(&:strip).reject { |line| line.empty? || line.include?("environment variable is being used") }.join(" ")
        raise TokenRequiredError,
          "gh did not accept the token: #{reason}\nIt needs #{RunnerUser.token_hint}. Re-run dev runner register with one, " \
          "or set it by hand:\n#{by_hand(runner_dir)}"
      end

      @token = token
    end

    # What register says when it cannot ask.
    #
    # @param runner_dir [String]
    # @return [String]
    sig { params(runner_dir: String).returns(String) }
    def headless_message(runner_dir)
      "The jobs of #{runner_dir} have no gh credential: the login in your keychain is unreadable from the runner " \
        "service. Give them a machine user's token (#{RunnerUser.token_hint}) once:\n#{by_hand(runner_dir)}\nthen re-run dev runner register."
    end

    # The by-hand form of what ensure! does.
    #
    # @param runner_dir [String]
    # @return [String]
    sig { params(runner_dir: String).returns(String) }
    def by_hand(runner_dir)
      "  echo '#{KEY}=<token>' >> #{runner_dir}/#{ENV_FILE} && chmod 600 #{runner_dir}/#{ENV_FILE}\n  " \
        "(cd #{runner_dir} && ./svc.sh stop && ./svc.sh start)"
    end

    # Stop or start the runner service when one is installed — a dir
    # with no service (register, before svc.sh install) has nothing to
    # bounce.
    #
    # @param runner_dir [String]
    # @param action [String] "stop" or "start"
    # @return [void]
    # @raise [ServiceRestartError]
    sig { params(runner_dir: String, action: String).void }
    def service!(runner_dir, action)
      return unless File.exist?(File.join(runner_dir, SERVICE_FILE))
      return if @exec.system(*RunnerSetup.service_argv(action, host_platform: @host_platform), chdir: runner_dir)

      raise ServiceRestartError, "svc.sh #{action} failed in #{runner_dir}"
    end
  end
end
