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
  # (DataRoot::LINUX_ROOT, dev#308) created as root, owned by the invoking
  # user and shared with the `dev` group (GROUP), then the per-user `~/.dev`
  # moved into it (DataRootMigration). The default root is in effect whether
  # or not the directory exists; this is the one step that makes it exist,
  # run by `dev up` on the host before anything installs.
  #
  # Admin work follows PrivilegedSteps' contract: probe without root first
  # (a present, writable, shared root is the steady state and costs
  # nothing), open one sudo session only when there is work, one argv per
  # step. With docker-ce's converge in the same `dev up`, sudo's credential
  # cache makes the two sessions one prompt.
  #
  # One root, two users (dev#310). The store embeds absolute paths and
  # warmth is path-bound, so a host has exactly one tree, and both the
  # operator and the runner user write it. The root is `<user>:dev 2775`:
  # the owner is whoever ran `dev up` first (a group granted this minute
  # is not in this login's credentials until the next, and the owner writes
  # regardless), setgid keeps every new entry in the group, and the group's
  # write bit is what the second user relies on — together with a `002`
  # umask, Ubuntu's default for a login and the runner service's by
  # configuration (RunnerSetup). A POSIX default ACL would not do better:
  # a new entry's group permissions are the ACL *intersected with* the mode
  # the creating process asked for, so an ACL never overrides a `022`
  # umask. A root that predates the group (dev#308's single-owner `0755`)
  # is converged in place — group and mode, down the tree, `secrets-<uid>`
  # dirs left alone — which changes no owner and is idempotent. A root that
  # exists but is not writable by this user belongs to another identity;
  # dev names the group fix and never re-owns it.
  class LinuxDataRootProvisioner
    extend T::Sig

    # The group the data root is shared with; both the operator and the
    # runner user are members.
    GROUP = "dev"

    # The root exists and this user cannot write it.
    class NotWritableError < RuntimeError; end

    # What a probe found.
    class Status < T::Struct
      const :present, T::Boolean
      const :writable, T::Boolean
      # In the group, group-writable, setgid: the shape a second user can
      # write through.
      const :shared, T::Boolean
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
    # @param group [String] the group it is shared with
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
                   user: T.must(Etc.getpwuid(Process.uid)).name, group: GROUP,
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
      Status.new(
        present: present,
        writable: present && File.writable?(@root) ? true : false,
        shared: present && shared? ? true : false,
      )
    end

    # Make the root exist, be this user's and the group's, then migrate
    # `~/.dev` into it. A present, writable, shared root is left alone; a
    # present, writable root not yet shared is converged in place and
    # nothing is migrated (it is already the data root in use).
    #
    # @return [void]
    # @raise [NotWritableError] the root exists and is another identity's
    # @raise [PrivilegedSteps::StepFailedError, PrivilegedSteps::SudoRequiredError]
    sig { void }
    def provision!
      current = status
      return if current.writable && current.shared

      if current.present && !current.writable
        raise NotWritableError,
          "#{@root} exists but #{@user} cannot write it. dev does not re-own a data root (dev#310). " \
          "If you are not yet in its group: sudo usermod -aG #{@group} #{@user}, then log in again; " \
          "if the root is not shared with the group yet, its owner's `dev up` shares it."
      end

      current.present ? share! : create!
      @out.puts "    #{@user} is in group #{@group} from the next login (the owner writes regardless)."
    end

    private

    # In the group, with the group's write bit and setgid.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def shared?
      stat = File.stat(@root)
      group = T.must(Etc.getgrgid(stat.gid)).name
      group == @group && (stat.mode & 0o2070) == 0o2070
    rescue ArgumentError
      false
    end

    # Create the root as root, hand it to the user and the group, migrate.
    #
    # @return [void]
    sig { void }
    def create!
      @out.puts ">>> Creating the data root #{@root}, shared with group #{@group} (one sudo prompt) ..."
      @steps.session!
      group_steps!
      @steps.step!("sudo", "install", "-d", "-o", @user, "-g", @group, "-m", "2775", @root)
      DataRootMigration.new(from: @home_dev, to: @root, out: @out).run!
    end

    # Converge a root that predates the group: group and mode, down the
    # tree, no owner touched. `secrets-<uid>` dirs are pruned — they are
    # per-identity by design (BuildContainer) and must not gain group bits.
    #
    # @return [void]
    sig { void }
    def share!
      @out.puts ">>> Sharing the data root #{@root} with group #{@group} (one sudo prompt) ..."
      @steps.session!
      group_steps!
      @steps.step!("sudo", "chgrp", "-Rh", @group, @root)
      @steps.step!(
        "sudo", "find", @root, "-name", "secrets-*", "-prune", "-o",
        "-type", "d", "-exec", "chmod", "g+rwxs", "{}", "+", "-o",
        "-exec", "chmod", "g+rw", "{}", "+"
      )
    end

    # The group exists and this user is in it; both idempotent.
    #
    # @return [void]
    sig { void }
    def group_steps!
      @steps.step!("sudo", "groupadd", "-f", @group)
      @steps.step!("sudo", "usermod", "-aG", @group, @user)
    end
  end
end
