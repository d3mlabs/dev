# typed: strict
# frozen_string_literal: true

require "fileutils"

require "dev/runner_setup"
require "dev/stream"
require "dev/ui"

module Dev
  # The job-started hook that follows a slot's stream: the runner's
  # `.env` names a script in `ACTIONS_RUNNER_HOOK_JOB_STARTED` — the
  # runner runs it before every job, with the job's `$GITHUB_PATH` and
  # `$GITHUB_ENV` writable — and dev's script runs `dev runner follow
  # <dir>`, which installs a moved head and exports its `bin`
  # (StreamFollower). The stream the slot follows is recorded next to it
  # as `DEV_STREAM=<repo>@gh ~> <major>`: the one record `dev runner
  # register` writes, the hook and `dev runner status` read.
  #
  # The runner reads `.env` once, at start, so a change here is applied
  # between a service stop and start — and only a change: a slot already
  # following its stream is not bounced for nothing. Files are written
  # as the enrollment's owner (the operator for its own, the runner user
  # through sudo for another's), as every runner-dir edit is
  # (RunnerSetup.remove_files).
  class StreamHook
    extend T::Sig

    # A write into the runner dir the owner refused.
    class WriteError < RuntimeError; end

    # svc.sh refused to stop or start the service around the change.
    class ServiceRestartError < RuntimeError; end

    # The runner's own env file: the listener exports every line of it.
    ENV_FILE = ".env"

    # The runner's job-started hook variable: an absolute script path.
    HOOK_ENV = "ACTIONS_RUNNER_HOOK_JOB_STARTED"

    # Where the stream a slot follows is recorded.
    STREAM_ENV = "DEV_STREAM"

    # The hook script, in the runner dir.
    SCRIPT = "dev-job-started.sh"

    # The record svc.sh writes at install: present means a service to bounce.
    SERVICE_FILE = ".service"

    # The env file's lines that are ours — rewritten whole on each converge.
    OWNED_KEYS = T.let([HOOK_ENV, STREAM_ENV].freeze, T::Array[String])

    class << self
      extend T::Sig

      # The stream a runner dir's hook follows, nil when it has none.
      #
      # @param runner_dir [String]
      # @return [Dev::Stream, nil]
      # @raise [Stream::MalformedError] when the record is not a stream (a
      #   hand edit; the message names the file to fix or re-register)
      sig { params(runner_dir: String).returns(T.nilable(Stream)) }
      def recorded(runner_dir)
        env_file = File.join(runner_dir, ENV_FILE)
        return nil unless File.file?(env_file)

        word = File.read(env_file).each_line(chomp: true).find { |line| line.start_with?("#{STREAM_ENV}=") }
        word && Stream.parse(word.delete_prefix("#{STREAM_ENV}="))
      rescue Stream::MalformedError => e
        raise Stream::MalformedError, "#{env_file}: #{STREAM_ENV} #{e.message} — re-run `dev runner register` to rewrite it"
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

    # Bring one runner dir's hook to the stream: record it and install
    # the script, or — stream nil, a role that anchors to a checkout —
    # remove both. Nothing happens when the dir already says so.
    #
    # @param runner_dir [String]
    # @param stream [Dev::Stream, nil]
    # @return [void]
    # @raise [WriteError]
    # @raise [ServiceRestartError]
    sig { params(runner_dir: String, stream: T.nilable(Stream)).void }
    def converge!(runner_dir:, stream:)
      env_file = File.join(runner_dir, ENV_FILE)
      script = File.join(runner_dir, SCRIPT)
      desired_env = env_content(current_env(env_file), script, stream)
      desired_script = stream && script_content(runner_dir)
      return if current_env(env_file) == desired_env && current_file(script) == desired_script

      @ui.step(stream ? "Pointing the job-started hook of #{runner_dir} at #{stream}" : "Removing the job-started hook of #{runner_dir}") do
        service!(runner_dir, "stop")
        write!(env_file, desired_env, mode: "0644")
        desired_script ? write!(script, desired_script, mode: "0755") : remove!(script)
        service!(runner_dir, "start")
      end
    end

    private

    # @param env_file [String]
    # @return [String] the env file as it stands, "" when absent
    sig { params(env_file: String).returns(String) }
    def current_env(env_file)
      current_file(env_file) || ""
    end

    # @param path [String]
    # @return [String, nil] the file's content, nil when absent
    sig { params(path: String).returns(T.nilable(String)) }
    def current_file(path)
      File.file?(path) ? File.read(path) : nil
    end

    # The env file with our lines replaced: every other line as it was
    # (the runner's own, an operator's), ours last.
    #
    # @param current [String]
    # @param script [String] the hook script's absolute path
    # @param stream [Dev::Stream, nil]
    # @return [String]
    sig { params(current: String, script: String, stream: T.nilable(Stream)).returns(String) }
    def env_content(current, script, stream)
      kept = current.each_line(chomp: true).reject { |line| OWNED_KEYS.any? { |key| line.start_with?("#{key}=") } }
      ours = stream ? ["#{HOOK_ENV}=#{script}", "#{STREAM_ENV}=#{stream}"] : []
      lines = kept + ours
      lines.empty? ? "" : "#{lines.join("\n")}\n"
    end

    # The hook script: one line of work, so what runs before a job is
    # read in the verb's own docs and tested as the verb.
    #
    # @param runner_dir [String]
    # @return [String]
    sig { params(runner_dir: String).returns(String) }
    def script_content(runner_dir)
      <<~SH
        #!/usr/bin/env bash
        # Written by `dev runner register`; rewritten on every register, so edit the role, not this file.
        # Runs before each job on this runner: installs the stream's head if it moved, exports its bin to the job's PATH.
        set -euo pipefail
        command -v dev >/dev/null || { echo "dev-job-started: dev is not on the runner's PATH (#{runner_dir}/.path)" >&2; exit 1; }
        exec dev runner follow #{runner_dir.inspect}
      SH
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

    # @param path [String]
    # @return [void]
    sig { params(path: String).void }
    def remove!(path)
      RunnerSetup.remove_files([File.basename(path)], dir: File.dirname(path), executor: @exec, as_user: @as_user)
    end

    # Stop or start the runner service when one is installed — a dir
    # with no service yet (register, before svc.sh install) has nothing
    # to bounce.
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
