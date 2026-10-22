# typed: strict
# frozen_string_literal: true

require "tempfile"

require "dev/process_executor"

module Dev
  # How dev performs admin steps on a Linux host — the one contract shared by
  # everything that needs root there (dockerd's converge, declared apt
  # packages): probe without root first, and only when there is work open one
  # sudo session, then run each privileged step as its own argv so a failure
  # names what failed. dev never edits sudoers and holds no standing grant.
  #
  # The session is the part that differs by situation. With a terminal,
  # `sudo -v` asks for the password once and the steps ride the cached
  # credential. Without one (a CI job, a runner service), nothing may wait on
  # a prompt: `sudo -n -v` succeeds on passwordless sudo (GitHub's hosted
  # images) and otherwise fails at once with SudoRequiredError — whose way
  # out is one interactive `dev up` on that host, the same contract Xcode's
  # install has on a Mac runner.
  #
  # Root-owned files are written by staging the content in a temp file and
  # `sudo install -m <mode>` — never by interpolating content into a shell.
  class PrivilegedSteps
    extend T::Sig

    # An admin step exited nonzero (a declined interactive prompt included).
    class StepFailedError < RuntimeError; end

    # Headless, and sudo would need a password nobody is there to type.
    class SudoRequiredError < RuntimeError; end

    # @param executor [#run] process seam; `run` streams so a sudo prompt reaches the TTY
    # @param tty [Boolean] whether a human is at a terminal (the session's shape)
    # @param purpose [String] what the privileged work is, for SudoRequiredError's message
    sig { params(executor: T.untyped, tty: T::Boolean, purpose: String).void }
    def initialize(executor: ProcessExecutor.new, tty: $stdin.tty?, purpose: "converge this host")
      @executor = executor
      @tty = tty
      @purpose = purpose
      @staged = T.let([], T::Array[Tempfile])
    end

    # Open the sudo session: one prompt with a terminal, a non-interactive
    # validation without one.
    #
    # @return [void]
    # @raise [StepFailedError] an interactive prompt was declined
    # @raise [SudoRequiredError] headless and sudo needs a password
    sig { void }
    def session!
      if @tty
        step!("sudo", "-v")
        return
      end
      return if T.unsafe(@executor).run("sudo", "-n", "-v")

      raise SudoRequiredError,
        "dev needs root to #{@purpose} and there is no terminal to ask on (sudo wants a password). " \
        "Run `dev up` interactively on this host once; after that every run is a probe."
    end

    # Run one privileged step.
    #
    # @param cmd [Array<String>] the full argv, `sudo` included
    # @return [void]
    # @raise [StepFailedError] naming the argv
    sig { params(cmd: String).void }
    def step!(*cmd)
      return if T.unsafe(@executor).run(*cmd)

      raise StepFailedError, "admin step failed: #{cmd.join(" ")}"
    end

    # Write +content+ to +path+ as root, at +mode+, from a staged copy.
    #
    # @param content [String]
    # @param path [String] destination (root-owned)
    # @param mode [String] octal mode for `install -m`
    # @return [void]
    # @raise [StepFailedError]
    sig { params(content: String, path: String, mode: String).void }
    def install_file!(content, path, mode:)
      step!("sudo", "install", "-m", mode, T.must(stage(content).path), path)
    end

    private

    # A temp file that outlives the install step (kept referenced until this
    # object goes).
    #
    # @param content [String]
    # @return [Tempfile]
    sig { params(content: String).returns(Tempfile) }
    def stage(content)
      file = Tempfile.new("dev-staged")
      file.write(content)
      file.flush
      @staged << file
      file
    end
  end
end
