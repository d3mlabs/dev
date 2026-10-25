# typed: strict
# frozen_string_literal: true

require "etc"
require "stringio"

require "dev/data_root"
require "dev/data_root_migration"
require "dev/platform"
require "dev/privileged_steps"

module Dev
  # Brings a Linux host's data root into being: `/var/lib/dev`
  # (DataRoot::LINUX_ROOT, dev#308) created as root and handed to the
  # invoking user, then the per-user `~/.dev` moved into it
  # (DataRootMigration). The default root is in effect whether or not the
  # directory exists; this is the one step that makes it exist, run by
  # `dev up` on the host before anything installs.
  #
  # Admin work follows PrivilegedSteps' contract: probe without root first
  # (a present, writable root is the steady state and costs nothing), open
  # one sudo session only when there is work, one argv per step. With
  # docker-ce's converge in the same `dev up`, sudo's credential cache makes
  # the two sessions one prompt.
  #
  # The root is owned by the invoking user at 0755 — the uid the Linux
  # bind mount then carries, which ADR-0006's aligner already handles
  # inside. A root that exists but is not writable by this user belongs to
  # another identity; dev names it and the command, and never re-owns it
  # (dev#310 is where identity lives).
  class LinuxDataRootProvisioner
    extend T::Sig

    # The root exists and this user cannot write it.
    class NotWritableError < RuntimeError; end

    # What a probe found.
    class Status < T::Struct
      const :present, T::Boolean
      const :writable, T::Boolean
    end

    class << self
      extend T::Sig

      # The provisioner for this host, or nil when the step does not apply:
      # not Linux, or `DEV_DATA_ROOT` points elsewhere (an override is the
      # user's to create).
      #
      # @param env [Hash{String => String}] process env
      # @param host_os [String] "darwin" / "linux" / "windows"
      # @return [LinuxDataRootProvisioner, nil]
      sig { params(env: T::Hash[String, String], host_os: String).returns(T.nilable(LinuxDataRootProvisioner)) }
      def for_host(env: ENV.to_h, host_os: Platform.os)
        return nil unless host_os == "linux"
        return nil unless env["DEV_DATA_ROOT"].to_s.empty?

        new
      end
    end

    # @param steps [Dev::PrivilegedSteps] the sudo contract
    # @param root [String] the data root to create
    # @param home_dev [String] the per-user root to migrate from
    # @param user [String] the owner the root is handed to
    # @param group [String] its group
    # @param out [IO, StringIO]
    sig do
      params(
        steps: PrivilegedSteps,
        root: String,
        home_dev: String,
        user: String,
        group: String,
        out: T.any(IO, StringIO),
      ).void
    end
    def initialize(steps: PrivilegedSteps.new(purpose: "create the data root #{DataRoot::LINUX_ROOT}"),
                   root: DataRoot::LINUX_ROOT, home_dev: File.expand_path(DataRoot::HOME_ROOT),
                   user: T.must(Etc.getpwuid(Process.uid)).name, group: T.must(Etc.getgrgid(Process.gid)).name,
                   out: $stdout)
      @steps = steps
      @root = root
      @home_dev = home_dev
      @user = user
      @group = group
      @out = out
    end

    # Probe without root.
    #
    # @return [Status]
    sig { returns(Status) }
    def status
      present = File.directory?(@root)
      Status.new(present: present, writable: present && File.writable?(@root) ? true : false)
    end

    # Make the root exist and be this user's, then migrate `~/.dev` into
    # it. A present, writable root is left alone.
    #
    # @return [void]
    # @raise [NotWritableError] the root exists and is another identity's
    # @raise [PrivilegedSteps::StepFailedError, PrivilegedSteps::SudoRequiredError]
    sig { void }
    def provision!
      current = status
      return if current.writable

      if current.present
        raise NotWritableError,
          "#{@root} exists but #{@user} cannot write it. dev does not re-own a data root (dev#310); " \
          "if it is yours: sudo chown -R #{@user}:#{@group} #{@root}"
      end

      @out.puts ">>> Creating the data root #{@root} (one sudo prompt) ..."
      @steps.session!
      @steps.step!("sudo", "install", "-d", "-o", @user, "-g", @group, "-m", "0755", @root)
      DataRootMigration.new(from: @home_dev, to: @root, out: @out).run!
    end
  end
end
