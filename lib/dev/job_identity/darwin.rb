# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"
require "tempfile"
require "yaml"

require "dev/job_identity"
require "dev/colima_provisioner"
require "dev/data_root"
require "dev/data_root_migration"
require "dev/runner_user"
require "dev/tap_trust"

module Dev
  class JobIdentity
    # A job identity on a Mac: the admin CLIs are Darwin's (sysadminctl,
    # dseditgroup, PlistBuddy), the runner user is the operator (the
    # service is a per-user LaunchAgent, so the sudoers edge is operator →
    # <user>), the data root is the shared root this adapter provisions
    # (DataRoot::SHARED_ROOT, with the one-off `~/.dev` migration), and
    # the identity has an engine of its own — colima, per-user by nature —
    # when the served repo pins an image.
    #
    # A shared root that is not the cooperative space `dev runner status`
    # inspects — in a group from before the one group name (`ai`), or in
    # the group without the setgid bit — is re-granted on the next run,
    # tree and all, so one name serves every host and ai-flow reads it
    # from the service env.
    class Darwin < JobIdentity
      extend T::Sig

      # The shared DDC directory under the shared root. UE disables a shared
      # cache store whose path is missing rather than creating it (probed on
      # ue5-mac 5.8), so register provisions the leaf; cellbound-3d's committed
      # DDC config points here (a cross-repo literal, duplicated knowingly like
      # the shared root itself).
      DDC_DIR = "ddc"

      # @param user [String] the OS user to provision
      # @param runner_user [String] the enrolling user (the sudoers grantor);
      #   defaults to whoever is running register
      # @param executor [#run, #quiet?, #capture] admin CLI seam
      # @param ui [Ui] where the convergence is told (JobIdentity)
      # @param data_root [String] where the shared data root is provisioned
      # @param home_dev [String] the per-user data dir migrated out of
      # @param launch_agents_dir [String] where svc.sh installs runner plists
      # @param brew_executable [String, nil] the host's brew binary
      #   (RunnerUser.brew_path; injectable for tests; nil = no lock dir
      #   to share, no tap to trust)
      # @param owner_of [Proc] who owns a path (injectable for tests)
      # @param tap [Dev::TapTrust::Tap, nil] the deployment's tap; nil for none
      sig do
        params(
          user: String,
          runner_user: String,
          executor: T.untyped,
          ui: Ui,
          data_root: String,
          home_dev: String,
          launch_agents_dir: String,
          brew_executable: T.nilable(String),
          owner_of: RunnerUser::OwnerOf,
          tap: T.nilable(TapTrust::Tap),
        ).void
      end
      def initialize(user:, runner_user: T.must(Etc.getpwuid(Process.uid)).name,
                     executor: Executor.new, ui: NoUi.new,
                     data_root: DataRoot::SHARED_ROOT, home_dev: File.expand_path(DataRoot::HOME_ROOT),
                     launch_agents_dir: File.join(Dir.home, "Library", "LaunchAgents"),
                     brew_executable: RunnerUser.brew_path,
                     owner_of: ->(path) { RunnerUser.owner_of(path) },
                     tap: TapTrust.deployment_tap)
        super(user: user, runner_user: runner_user, executor: executor, ui: ui, data_root: data_root,
          brew_executable: brew_executable, owner_of: owner_of, tap: tap)
        @home_dev = home_dev
        @launch_agents_dir = launch_agents_dir
      end

      # Step 6: the identity's own engine — colima installed (the macOS
      # engine, per-user by nature), its `container_engine: colima` record
      # written into its own config (resolution never crosses the sudo
      # boundary), and its VM provisioned, sized from the repo's resources
      # hint. Every colima invocation crosses to the identity via sudo.
      #
      # @param cpus [Integer, nil] VM sizing hint (repo resources block)
      # @param memory_gib [Integer, nil] VM sizing hint
      # @param disk_gib [Integer, nil] VM disk hint (grow-only)
      # @return [void]
      # @raise [StepFailedError] when a converge step fails
      # @raise [Dev::ColimaProvisioner::StartFailedError] when the VM won't start
      sig { override.params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
      def ensure_engine!(cpus: nil, memory_gib: nil, disk_gib: nil)
        # Prime the sudo credential once, visibly, so the -n probes below
        # never hang on a captured password prompt.
        step!("sudo", "-v")
        ensure_colima_installed!
        ensure_engine_record!
        ColimaProvisioner
          .new(executor: @as_user)
          .provision!(cpus: cpus, memory_gib: memory_gib, disk_gib: disk_gib)
      end

      # The identity's config content carrying the engine record, merged
      # over whatever its config already holds (never clobbers other keys).
      #
      # @param existing [String] current config YAML ("" when absent)
      # @return [String]
      sig { params(existing: String).returns(String) }
      def user_config_content(existing)
        parsed = YAML.safe_load(existing)
        config = parsed.is_a?(Hash) ? parsed : {}
        YAML.dump(config.merge("container_engine" => "colima"))
      end

      # @param member [String] a user name
      # @return [Boolean]
      sig { override.params(member: String).returns(T::Boolean) }
      def group_member?(member)
        @executor.quiet?("dseditgroup", "-o", "checkmember", "-m", member, DataRoot::GROUP)
      end

      # @return [Boolean]
      sig { override.returns(T::Boolean) }
      def engine_converged?
        @executor.quiet?("brew", "list", "--formula", "colima")
      end

      # @return [String]
      sig { override.returns(String) }
      def engine_fact
        "colima installed (container engine)"
      end

      private

      # Hidden and non-admin by construction: no -admin flag, IsHidden set
      # right after creation, home materialized so the identity's per-user
      # state has a place to land before the first job.
      sig { override.void }
      def create_user!
        step!("sudo", "sysadminctl", "-addUser", @user, "-fullName", "AI Agent", "-shell", "/bin/zsh")
        step!("sudo", "dscl", ".", "create", "/Users/#{@user}", "IsHidden", "1")
        step!("sudo", "createhomedir", "-c", "-u", @user)
      end

      sig { override.returns(T::Boolean) }
      def group_exists?
        @executor.quiet?("dseditgroup", "-o", "read", DataRoot::GROUP)
      end

      sig { override.void }
      def create_group!
        step!("sudo", "dseditgroup", "-o", "create", DataRoot::GROUP)
      end

      # @param member [String]
      sig { override.params(member: String).void }
      def add_group_member!(member)
        step!("sudo", "dseditgroup", "-o", "edit", "-a", member, "-t", "user", DataRoot::GROUP)
      end

      # The shared data root both identities resolve (see Dev::DataRoot —
      # presence is the record), plus the shared DDC leaf the engine
      # expects to pre-exist (DDC_DIR). Fresh dirs get cooperative modes:
      # human-owned so `dev up` writes it, the group + setgid +
      # group-writable so cooperative caches (the shared DDC) work, world-
      # readable so the identity reads it like /opt/homebrew. An existing root
      # is held to what `dev runner status` inspects of it (#cooperative_dir?)
      # and re-granted when it falls short — its owner is never changed.
      # Then the one-off migration.
      sig { override.void }
      def ensure_data_root!
        existed = File.directory?(@data_root)
        ensure_cooperative_dir!(@data_root, "the shared root")
        ensure_cooperative_dir!(File.join(@data_root, DDC_DIR), "the shared DDC")
        grant_data_root! if existed
        migrate_home_artifacts!
      end

      # mkdir + cooperative modes for a shared directory, first time only.
      #
      # @param path [String] absolute directory to provision
      # @param description [String] what the progress line calls it
      sig { params(path: String, description: String).void }
      def ensure_cooperative_dir!(path, description)
        return if File.directory?(path)

        @ui.step("Provisioning #{description} at #{path}") do
          FileUtils.mkdir_p(path)
          step!("sudo", "chown", @runner_user, path)
          step!("sudo", "chgrp", DataRoot::GROUP, path)
          step!("sudo", "chmod", "2775", path)
        end
      end

      # An existing root that is not the cooperative space status inspects
      # — the group and the setgid bit — gets the same grant the `_work`
      # tree does (#grant_work_tree!): the group, group-writable
      # throughout, setgid on every dir, tree and all. Converging exactly
      # what is inspected is what keeps register's ✓ and status's ✗ from
      # disagreeing: the Mac's root sat in group `dev` without setgid once
      # a re-group alone had moved it off the legacy `ai` name. Symlinks
      # are re-grouped themselves, never followed (`-h`), as the Linux
      # provisioner's share does. A root already `2775` in the group is a
      # no-op.
      sig { void }
      def grant_data_root!
        return if cooperative_dir?(@data_root)

        @ui.step("Granting the #{DataRoot::GROUP} group cooperative access to #{@data_root}") do
          step!("sudo", "chgrp", "-Rh", DataRoot::GROUP, @data_root)
          step!("sudo", "chmod", "-R", "g+rwX", @data_root)
          step!("sudo", "find", @data_root, "-type", "d", "-exec", "chmod", "g+s", "{}", "+")
        end
      end

      # The one-off ~/.dev migration into the shared root (DataRootMigration:
      # artifacts move, `state` stays per-home, what the root holds is kept).
      sig { void }
      def migrate_home_artifacts!
        DataRootMigration.new(from: @home_dev, to: @data_root, ui: @ui).run!
      end

      # @return [String] the identity's own settings file
      sig { returns(String) }
      def user_config_path
        "/Users/#{@user}/.config/dev/config.yml"
      end

      # colima arrives via brew like every host tool ("brew converges brew").
      sig { void }
      def ensure_colima_installed!
        return if engine_converged?

        @ui.step("Installing colima") { step!("brew", "install", "colima") }
      end

      # Write `container_engine: colima` into the identity's own config,
      # owned by it, preserving any other keys already there.
      sig { void }
      def ensure_engine_record!
        existing = @executor.capture("sudo", "cat", user_config_path)
        parsed = YAML.safe_load(existing)
        return if parsed.is_a?(Hash) && parsed["container_engine"] == "colima"

        @ui.step("Recording container_engine: colima for #{@user}") do
          step!("sudo", "-H", "-u", @user, "--", "mkdir", "-p", File.dirname(user_config_path))
          Tempfile.create("agent-dev-config") do |staging|
            staging.write(user_config_content(existing))
            staging.flush
            File.chmod(0o644, staging.path)
            step!("sudo", "install", "-m", "0644", "-o", @user, staging.path, user_config_path)
          end
        end
      end

      # The runner service plist carries the service env — Umask 002 and
      # #service_env — applied between a service stop/start so launchd
      # rereads it. The plist location comes from the `.service` record
      # svc.sh wrote at install: the full plist path, or (a hand-installed
      # service) the bare name, resolved under launch_agents_dir. svc.sh
      # runs as the operator here — under sudo it would address a root
      # agent that never loads into the user's launchd session
      # (RunnerSetup.service_argv).
      #
      # @param runner_dir [String]
      # @param slot [Integer] which of the host's slots this runner is
      # @raise [StepFailedError] when no service was installed in runner_dir
      sig { override.params(runner_dir: String, slot: Integer).void }
      def configure_service!(runner_dir, slot)
        service = service_record(runner_dir)
        plist = service.end_with?(".plist") ? service : File.join(@launch_agents_dir, "#{service}.plist")
        env = service_env(slot)
        @ui.step("Writing Umask 002 + #{env.map { |key, value| "#{key}=#{value}" }.join(" + ")} into #{plist}") do
          step!("./svc.sh", "stop", chdir: runner_dir)
          plist_set!(plist, "Umask", "integer", "2")
          # The EnvironmentVariables dict may not exist yet; a failed Add just
          # means it already does.
          @executor.run("/usr/libexec/PlistBuddy", "-c", "Add :EnvironmentVariables dict", plist)
          env.each { |key, value| plist_set!(plist, "EnvironmentVariables:#{key}", "string", value) }
          step!("./svc.sh", "start", chdir: runner_dir)
        end
      end

      # Set a plist key, adding it when Set finds none (PlistBuddy's Set fails
      # on missing keys; Add fails on existing ones — together they converge).
      #
      # @param plist [String] plist path
      # @param key [String] colon-path below the root
      # @param type [String] PlistBuddy type for Add
      # @param value [String]
      sig { params(plist: String, key: String, type: String, value: String).void }
      def plist_set!(plist, key, type, value)
        return if @executor.run("/usr/libexec/PlistBuddy", "-c", "Set :#{key} #{value}", plist)

        step!("/usr/libexec/PlistBuddy", "-c", "Add :#{key} #{type} #{value}", plist)
      end

      # BSD stat: the group name and the symbolic mode.
      #
      # @param path [String]
      # @return [Array<String>]
      sig { override.params(path: String).returns(T::Array[String]) }
      def stat_argv(path)
        ["stat", "-f", "%Sg %Sp", path]
      end
    end
  end
end
