# typed: strict
# frozen_string_literal: true

require "fileutils"
require "stringio"

require "dev/runner_discovery"
require "dev/runner_setup"

module Dev
  # The exact inverse of RunnerSetup: removes one of this host's runner
  # enrollments — its service, its GitHub registration, and the files that
  # make the dir an enrollment — leaving the runner binaries in place so
  # the dir is an unconfigured download a later `register --dir` can
  # reuse, and its _diag logs stay readable.
  #
  # Order matters and follows the runner's own rules: config.sh refuses to
  # deregister while the service unit is installed ("Uninstall service
  # first"), so the service goes first; the remove token is minted at the
  # enrollment's *own* scope (read from its .runner record), never at a
  # target scope; and a registration the server no longer has — the state
  # `config.sh --replace` leaves an older dir in — counts as removed, not
  # as a failure.
  #
  # Enrollments are named the way an operator would: by scope when one
  # local enrollment serves it, or by dir (absolute or `~`-relative), which
  # is always unambiguous. Both come from RunnerDiscovery and nothing
  # else, so resolution works offline (shell completion rides on it).
  #
  # Same CLI boundary as RunnerSetup (an injectable Executor over gh /
  # svc.sh / config.sh) and the same svc.sh OS split.
  class RunnerTeardown
    extend T::Sig

    class Error < StandardError; end

    # A scope several local enrollments serve: naming it does not name an
    # enrollment. The message lists the dirs, which do.
    class AmbiguousEnrollmentError < Error; end

    # Nothing on this host is enrolled under that scope or lives in that
    # dir.
    class NoSuchEnrollmentError < Error; end

    # A step the runner's own scripts refused (svc.sh, config.sh, token
    # minting) for a reason other than the registration being gone. The
    # enrollment is left as it was at that step.
    class TeardownFailedError < Error; end

    # What config.sh says when the registration it would remove is not on
    # the server — superseded by `--replace`, or already removed. The
    # admin-flow delete answers 404; the legacy flow prints "Does not
    # exist" and exits 0 on its own.
    GONE_PATTERN = T.let(/404|not found|does not exist/i, Regexp)

    # The files that make a runner dir an enrollment: config.sh writes the
    # first three, svc.sh the fourth. Without them the dir is a download.
    ENROLLMENT_FILES = T.let(%w[.runner .credentials .credentials_rsaparams .service].freeze, T::Array[String])

    # @param discovery [Dev::RunnerDiscovery] this host's enrollments
    # @param executor [#capture, #system] CLI boundary (default: the real
    #   one; injectable for tests)
    # @param out [IO, StringIO] progress stream
    # @param host_platform [String] actions-runner platform slug; drives the
    #   svc.sh sudo split (systemd vs LaunchAgent)
    # @param home [String] what a leading `~` in a dir reference expands to
    sig do
      params(
        discovery: Dev::RunnerDiscovery,
        executor: T.untyped,
        out: T.any(IO, StringIO),
        host_platform: String,
        home: String,
      ).void
    end
    def initialize(discovery: Dev::RunnerDiscovery.new, executor: RunnerSetup::Executor.new, out: $stdout,
                   host_platform: RunnerSetup.detect_host_platform, home: Dir.home)
      @discovery = discovery
      @exec = executor
      @out = out
      @host_platform = host_platform
      @home = home
    end

    # The enrollment a command-line reference names. A reference starting
    # with `/` or `~` is a dir; anything else is a scope ("owner/repo" or
    # "owner").
    #
    # @param reference [String]
    # @return [Dev::RunnerDiscovery::Enrollment]
    # @raise [AmbiguousEnrollmentError] when the scope has several enrollments
    # @raise [NoSuchEnrollmentError] when nothing matches
    sig { params(reference: String).returns(Dev::RunnerDiscovery::Enrollment) }
    def resolve(reference)
      return resolve_dir(reference) if reference.start_with?("/", "~")

      matches = @discovery.enrollments_for(reference)
      if matches.length > 1
        raise AmbiguousEnrollmentError,
          "#{matches.length} enrollments on this host serve #{reference} — name the dir instead: " \
            "#{matches.map(&:display_dir).join(", ")}"
      end

      matches.fetch(0) { raise NoSuchEnrollmentError, "no enrollment on this host serves #{reference}" }
    end

    # Remove the enrollment: stop and uninstall its service when one is
    # installed, deregister it at its own scope, clear the enrollment
    # files. One line of output names what happened and where.
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @return [void]
    # @raise [TeardownFailedError] when a step is refused; the enrollment
    #   is left at that step
    sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).void }
    def teardown!(enrollment)
      service = enrollment.service_installed ? uninstall_service(enrollment.dir) : "no service installed"
      registration = deregister(enrollment)
      ENROLLMENT_FILES.each { |file| FileUtils.rm_f(File.join(enrollment.dir, file)) }
      @out.puts ">>> Unregistered #{enrollment.name} from #{enrollment.scope} (#{enrollment.display_dir}): " \
                "#{service}, #{registration}, enrollment files cleared; binaries left in place."
    end

    private

    # @param reference [String] an absolute or `~`-relative dir
    # @return [Dev::RunnerDiscovery::Enrollment]
    # @raise [NoSuchEnrollmentError] when no enrollment lives there
    sig { params(reference: String).returns(Dev::RunnerDiscovery::Enrollment) }
    def resolve_dir(reference)
      # File.expand_path reads `~` from $HOME; the discovery's home is the
      # one that counts (and the one tests redirect).
      dir = reference.start_with?("~") ? File.join(@home, reference.delete_prefix("~")) : reference
      dir = File.expand_path(dir).chomp("/")
      enrollment = @discovery.enrollments.find { |candidate| candidate.dir == dir }
      enrollment || raise(NoSuchEnrollmentError, "no enrollment lives in #{reference}")
    end

    # svc.sh stop then uninstall, in the dir.
    #
    # @param dir [String]
    # @return [String] what happened, for the summary line
    # @raise [TeardownFailedError] when svc.sh refuses
    sig { params(dir: String).returns(String) }
    def uninstall_service(dir)
      @out.puts ">>> Stopping + uninstalling the runner service ..."
      %w[stop uninstall].each do |action|
        argv = RunnerSetup.service_argv(action, host_platform: @host_platform)
        next if @exec.system(*argv, chdir: dir)

        raise TeardownFailedError, "svc.sh #{action} failed in #{dir}"
      end
      "service stopped and uninstalled"
    end

    # `config.sh remove` with a remove token minted at the enrollment's own
    # scope. Its output is echoed; a failure that says the registration is
    # not on the server is success.
    #
    # @param enrollment [Dev::RunnerDiscovery::Enrollment]
    # @return [String] what happened, for the summary line
    # @raise [TeardownFailedError] when the token can't be minted or
    #   config.sh fails for another reason
    sig { params(enrollment: Dev::RunnerDiscovery::Enrollment).returns(String) }
    def deregister(enrollment)
      @out.puts ">>> Removing the registration at #{enrollment.scope} ..."
      token = RunnerSetup.mint_token(enrollment.scope, "remove-token", executor: @exec)
      out, err, ok = @exec.capture("./config.sh", "remove", "--token", token, chdir: enrollment.dir)
      @out.print(out) unless out.empty?
      return "registration removed" if ok

      output = "#{out}\n#{err}".strip
      return "registration already gone from the server" if output.match?(GONE_PATTERN)

      raise TeardownFailedError, "config.sh remove failed in #{enrollment.dir}: #{output}"
    rescue RunnerSetup::Error => e
      raise TeardownFailedError, e.message
    end
  end
end
