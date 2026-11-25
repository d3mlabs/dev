# typed: strict
# frozen_string_literal: true

require "dev/runner_setup"
require "dev/ui"

module Dev
  # The job-started hook dev 0.9.x installed in a slot's runner dir, and
  # its removal — one release's migration (dev#700). Under dev#658 `dev
  # runner register` from a project deployed through gh wrote
  # `ACTIONS_RUNNER_HOOK_JOB_STARTED=<dir>/dev-job-started.sh` and
  # `DEV_STREAM=<repo>@gh ~> <major>` into the runner's `.env` and the
  # script beside it; the hook installed the series head before each job.
  # Hosts follow no stream now — what a job runs comes from the adopting
  # project's lock, installed by the job's own `dev up` — so a slot
  # carrying the hook is a slot from before: register removes it (the
  # env keys, the script) and bounces the service once, since the runner
  # reads `.env` at start; `dev runner status` names a leftover as drift
  # until then. A slot without one is left untouched.
  #
  # Files are removed as the enrollment's owner (the operator for its
  # own, the runner user through sudo for another's), as every runner-dir
  # edit is (RunnerSetup.remove_files).
  class RetiredJobHook
    extend T::Sig

    # A write into the runner dir the owner refused.
    class WriteError < RuntimeError; end

    # svc.sh refused to stop or start the service around the change.
    class ServiceRestartError < RuntimeError; end

    # The runner's own env file: the listener exports every line of it.
    ENV_FILE = ".env"

    # The runner's job-started hook variable, as dev 0.9.x set it.
    HOOK_ENV = "ACTIONS_RUNNER_HOOK_JOB_STARTED"

    # Where dev 0.9.x recorded the stream a slot followed.
    STREAM_ENV = "DEV_STREAM"

    # The hook script dev 0.9.x wrote, in the runner dir.
    SCRIPT = "dev-job-started.sh"

    # The record svc.sh writes at install: present means a service to bounce.
    SERVICE_FILE = ".service"

    # The env file's lines that were dev's.
    RETIRED_KEYS = T.let([HOOK_ENV, STREAM_ENV].freeze, T::Array[String])

    class << self
      extend T::Sig

      # Whether a runner dir still carries the retired hook: any of its
      # env keys, or the script.
      #
      # @param runner_dir [String]
      # @return [Boolean]
      sig { params(runner_dir: String).returns(T::Boolean) }
      def present?(runner_dir)
        return true if File.file?(File.join(runner_dir, SCRIPT))

        env_file = File.join(runner_dir, ENV_FILE)
        File.file?(env_file) && File.read(env_file).each_line(chomp: true).any? { |line| retired?(line) }
      end

      # @param line [String] one line of the runner's `.env`
      # @return [Boolean] whether it is one of the retired keys
      sig { params(line: String).returns(T::Boolean) }
      def retired?(line)
        RETIRED_KEYS.any? { |key| line.start_with?("#{key}=") }
      end
    end

    # @param executor [#system, #capture] runs svc.sh and the owner's writes
    # @param host_platform [String] actions-runner platform slug; drives the svc.sh sudo split
    # @param as_user [String, nil] the enrollment's owner when not the operator
    # @param ui [Ui]
    sig { params(executor: T.untyped, host_platform: String, as_user: T.nilable(String), ui: Ui).void }
    def initialize(executor: RunnerSetup::Executor.new, host_platform: RunnerSetup.detect_host_platform, as_user: nil, ui: NoUi.new)
      @exec = executor
      @host_platform = host_platform
      @as_user = as_user
      @ui = ui
    end

    # Remove the retired hook from one runner dir: the env keys leave
    # `.env` (every other line stays as it was), the script goes, and the
    # service is bounced around the change. Nothing happens when the dir
    # carries none.
    #
    # @param runner_dir [String]
    # @return [void]
    # @raise [WriteError]
    # @raise [ServiceRestartError]
    sig { params(runner_dir: String).void }
    def remove!(runner_dir:)
      return unless self.class.present?(runner_dir)

      env_file = File.join(runner_dir, ENV_FILE)
      @ui.step("Removing the job-started hook of #{runner_dir} (hosts follow no stream; the job's `dev up` installs the lock)") do
        service!(runner_dir, "stop")
        write!(env_file, kept_env(env_file), mode: "0644") if File.file?(env_file)
        RunnerSetup.remove_files([SCRIPT], dir: runner_dir, executor: @exec, as_user: @as_user)
        service!(runner_dir, "start")
      end
    end

    private

    # The env file without the retired keys: the runner's own lines and
    # an operator's, in their order.
    #
    # @param env_file [String]
    # @return [String]
    sig { params(env_file: String).returns(String) }
    def kept_env(env_file)
      kept = File.read(env_file).each_line(chomp: true).reject { |line| self.class.retired?(line) }
      kept.empty? ? "" : "#{kept.join("\n")}\n"
    end

    # Write a file in the runner dir as its owner.
    #
    # @param path [String]
    # @param content [String]
    # @param mode [String] an octal mode word
    # @return [void]
    # @raise [WriteError]
    sig { params(path: String, content: String, mode: String).void }
    def write!(path, content, mode:)
      as_user = @as_user
      if as_user
        _out, err, ok = @exec.capture(*RunnerSetup.as_user_argv(as_user, ["tee", path]), stdin: content)
        raise WriteError, "could not write #{path} as #{as_user}: #{err.strip}" unless ok
        raise WriteError, "could not chmod #{path} as #{as_user}" unless @exec.system(*RunnerSetup.as_user_argv(as_user, ["chmod", mode, path]))
      else
        File.write(path, content)
        File.chmod(Integer(mode, 8), path)
      end
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
