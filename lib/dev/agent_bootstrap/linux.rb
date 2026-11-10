# typed: strict
# frozen_string_literal: true

require "stringio"
require "tempfile"

require "dev/agent_bootstrap"
require "dev/data_root"
require "dev/runner_user"
require "dev/tap_trust"

module Dev
  class AgentBootstrap
    # The agent host contract on a Linux dev host (plans#59): the same facts
    # as the Mac's, established with the host's own CLIs — `useradd` and
    # `usermod` for the identities, the same visudo-staged sudoers drop-in,
    # a systemd unit drop-in for the service env. Three identities meet
    # here (dev#310): the operator registers, the *runner user* owns the
    # enrollment and its service — so the spawn edge is `runner → agent`,
    # and the brew edge targets the runner user's Linuxbrew prefix
    # (dev#337) — and the agent holds nothing on the host.
    #
    # Nothing is provisioned for the data root: `/var/lib/dev` and its
    # group exist from LinuxDataRootProvisioner (the `dev up` and
    # `register` on this host before this step), so the agent joins the
    # group and the root's shape is asserted, never changed.
    #
    # No engine step. The agent needs an engine only for an image-built
    # repo, and the only engine on a Linux box is the runner user's rootful
    # docker, whose socket is root-equivalent — handing it across the UID
    # line would make the agent user decorative (plans#26 layer 5). For
    # such a repo the agent runs *inside* the project's container, spawned
    # there by the dispatcher (plans#61); until that lands, a served repo
    # that pins an image is refused here with that pointer.
    class Linux < AgentBootstrap
      extend T::Sig

      # A served repo pins an image, and this host has no agent engine to
      # offer: the agent for an image-built repo runs inside the project's
      # container (plans#61), not on the host.
      class NoAgentEngineError < RuntimeError; end

      # The data root is not the cooperative space the agent reads
      # through the group — missing, another group's, or not setgid.
      class DataRootNotSharedError < RuntimeError; end

      # Where systemd reads unit drop-ins from.
      SYSTEMD_DIR = "/etc/systemd/system"

      # The drop-in file dev owns under `<unit>.d/`; everything else in the
      # unit is svc.sh's.
      DROP_IN_NAME = "ai-flow-agent.conf"

      # The one explanation, for the engine refusal and the status line.
      NO_ENGINE_MESSAGE = "an image-built repo's agent has no engine of its own on a Linux host — the only engine " \
        "here is the runner user's docker, whose socket is root-equivalent across the user line (plans#26). Its " \
        "agent runs inside the project's container instead (plans#61); until that lands, this host cannot serve " \
        "agent labels for a repo that pins an image."

      # Every command run as the agent starts from `/`: sudo keeps the
      # caller's cwd, which is the operator's checkout under a home the
      # agent cannot enter, and brew refuses to run from a directory it
      # cannot stat (dev#493, the RunnerUser rule). GNU env is a given on
      # Linux.
      AS_AGENT_PRELUDE = T.let(%w[env -C /].freeze, T::Array[String])

      # @param agent_user [String] the run-as user to provision
      # @param runner_user [String] the host rule's runner user (RunnerUser),
      #   whose service spawns the agent
      # @param executor [#run, #quiet?, #capture] admin CLI seam
      # @param ui [Ui] where the convergence is told (AgentBootstrap)
      # @param data_root [String] the host's data root (DataRoot::LINUX_ROOT)
      # @param systemd_dir [String] where unit drop-ins land
      # @param brew_executable [String, nil] the host's brew binary (discovered
      #   from BREW_LOCATIONS; nil = no brew edge, no tap to trust)
      # @param owner_of [Proc] who owns a path (injectable for tests)
      # @param tap [Dev::TapTrust::Tap, nil] the deployment's tap; nil for none
      sig do
        params(
          agent_user: String,
          runner_user: String,
          executor: T.untyped,
          ui: Ui,
          data_root: String,
          systemd_dir: String,
          brew_executable: T.nilable(String),
          owner_of: RunnerUser::OwnerOf,
          tap: T.nilable(TapTrust::Tap),
        ).void
      end
      def initialize(agent_user: DEFAULT_AGENT_USER, runner_user: RunnerUser::DEFAULT_NAME,
                     executor: Executor.new, ui: NoUi.new,
                     data_root: DataRoot::LINUX_ROOT, systemd_dir: SYSTEMD_DIR,
                     brew_executable: BREW_LOCATIONS.find { |path| File.exist?(path) },
                     owner_of: ->(path) { RunnerUser.owner_of(path) },
                     tap: TapTrust.deployment_tap)
        super(agent_user: agent_user, runner_user: runner_user, executor: executor, ui: ui, data_root: data_root,
          brew_executable: brew_executable, owner_of: owner_of, tap: tap, as_agent_prelude: AS_AGENT_PRELUDE)
        @systemd_dir = systemd_dir
      end

      # Refused: see the class comment.
      #
      # @param cpus [Integer, nil] unused
      # @param memory_gib [Integer, nil] unused
      # @param disk_gib [Integer, nil] unused
      # @return [void]
      # @raise [NoAgentEngineError] always
      sig { override.params(cpus: T.nilable(Integer), memory_gib: T.nilable(Integer), disk_gib: T.nilable(Integer)).void }
      def ensure_agent_engine!(cpus: nil, memory_gib: nil, disk_gib: nil)
        raise NoAgentEngineError, NO_ENGINE_MESSAGE
      end

      # @param member [String] a user name
      # @return [Boolean]
      sig { override.params(member: String).returns(T::Boolean) }
      def group_member?(member)
        @executor.capture("id", "-nG", member).split.include?(DataRoot::GROUP)
      end

      # @return [Boolean] never — there is no engine to converge
      sig { override.returns(T::Boolean) }
      def engine_converged?
        false
      end

      # @return [String]
      sig { override.returns(String) }
      def engine_fact
        "agent engine: #{NO_ENGINE_MESSAGE}"
      end

      # The systemd drop-in content: a 002 umask (a service's umask is not
      # the login's, so Ubuntu's 002 default does not reach it — without
      # this the runner user's next `dev up` hits a tree the agent wrote
      # 755, dev#310's tripwire) and #service_env, one `Environment=` each.
      #
      # @param slot [Integer] 1-based
      # @return [String]
      sig { params(slot: Integer).returns(String) }
      def drop_in_content(slot)
        lines = ["[Service]", "UMask=0002"]
        service_env(slot).each { |key, value| lines << "Environment=#{key}=#{value}" }
        "#{lines.join("\n")}\n"
      end

      private

      # A login shell and a home of its own; no supplementary group yet
      # (the cooperative group is the next step's), no sudo, no password.
      # "Hidden" has no Linux meaning.
      sig { override.void }
      def create_agent_user!
        step!("sudo", "useradd", "-m", "-s", "/bin/bash", @agent_user)
      end

      sig { override.returns(T::Boolean) }
      def group_exists?
        @executor.quiet?("getent", "group", DataRoot::GROUP)
      end

      # The provisioner made it; this is the belt for a host whose root
      # came from elsewhere.
      sig { override.void }
      def create_group!
        step!("sudo", "groupadd", "-f", DataRoot::GROUP)
      end

      # @param member [String]
      sig { override.params(member: String).void }
      def add_group_member!(member)
        step!("sudo", "usermod", "-aG", DataRoot::GROUP, member)
      end

      # Nothing to create: the root is LinuxDataRootProvisioner's, in the
      # group, setgid and group-writable (`<owner>:dev 2775`). Asserted,
      # because the agent reads the store through that group and dev never
      # re-owns a root (dev#310).
      #
      # @raise [DataRootNotSharedError] when the root is not that shape
      sig { override.void }
      def ensure_data_root!
        return if cooperative_dir?(@data_root)

        raise DataRootNotSharedError,
          "#{@data_root} is not shared with group #{DataRoot::GROUP} (setgid, group-writable) — the agent reads the " \
          "store through that group. Run `dev up` on this host once (LinuxDataRootProvisioner shares the root), " \
          "then re-run dev runner register."
      end

      # The runner service's unit gets a drop-in (`<unit>.d/ai-flow-agent.conf`)
      # carrying #drop_in_content, root-owned 0644, applied between a
      # service stop and start with a daemon-reload in between so systemd
      # rereads it. The unit's name is the `.service` record svc.sh wrote
      # (the bare unit name, `.service` suffix included). svc.sh needs root
      # on Linux (RunnerSetup.service_argv). A drop-in already saying this
      # is left alone — the service is not bounced for nothing.
      #
      # @param runner_dir [String]
      # @param slot [Integer] which of the host's slots this runner is
      # @raise [StepFailedError] when no service was installed in runner_dir
      sig { override.params(runner_dir: String, slot: Integer).void }
      def configure_service!(runner_dir, slot)
        unit = service_record(runner_dir)
        unit = "#{unit}.service" unless unit.end_with?(".service")
        drop_in = File.join(@systemd_dir, "#{unit}.d", DROP_IN_NAME)
        desired = drop_in_content(slot)
        return if File.exist?(drop_in) && File.read(drop_in) == desired

        env = service_env(slot)
        @ui.step("Writing UMask 0002 + #{env.map { |key, value| "#{key}=#{value}" }.join(" + ")} into #{drop_in}") do
          step!("sudo", "./svc.sh", "stop", chdir: runner_dir)
          step!("sudo", "install", "-d", "-m", "0755", File.dirname(drop_in))
          Tempfile.create("ai-flow-agent-dropin") do |staging|
            staging.write(desired)
            staging.flush
            File.chmod(0o644, staging.path)
            step!("sudo", "install", "-m", "0644", staging.path, drop_in)
          end
          step!("sudo", "systemctl", "daemon-reload")
          step!("sudo", "./svc.sh", "start", chdir: runner_dir)
        end
      end

      # GNU stat: the group name and the symbolic mode.
      #
      # @param path [String]
      # @return [Array<String>]
      sig { override.params(path: String).returns(T::Array[String]) }
      def stat_argv(path)
        ["stat", "-c", "%G %A", path]
      end
    end
  end
end
