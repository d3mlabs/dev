# typed: strict
# frozen_string_literal: true

require "open3"

require "dev/deps"
require "dev/engine_resources"
require "dev/settings"

module Dev
  # Which container engine docker invocations ride — the per-user container
  # substrate. Whether a repo's build runs containerized is a repo-shape
  # detail; *which daemon serves it* is a per-user provisioning decision, so
  # the engine is resolved from the invoking user's own config and injected
  # into everything that composes docker argv (BuildContainer, BuildWatcher,
  # CacheGc). One engine per host OS: macOS users (human and agent alike)
  # ride their own colima VM — the only macOS engine whose whole lifecycle
  # dev can own (start, idle-stop, resize); Linux and WSL2 ride the bare
  # dockerd already running on the host, where there is no VM to own. A
  # remote engine later joins as config, never an architecture fork.
  #
  # Resolution order (see .resolve): explicit DOCKER_HOST in the caller's
  # environment → the per-user `container_engine` settings record → the host
  # OS's default engine.
  #
  # The load-bearing capability predicate is #local_mounts?: bind-mounting
  # local paths (`-v project_root:/project`) is the single remote-poisoned
  # assumption in dev's container code. Both shipped engines answer true; a
  # remote engine answers false and brings its sync strategy with it.
  class ContainerEngine
    extend T::Sig

    # The per-user engine record names an engine dev does not ship.
    class UnknownEngineError < RuntimeError; end

    # The colima profile dev provisions and points at (colima's own default).
    COLIMA_PROFILE = "default"

    # The label contract dev stamps on every container it creates (see
    # BuildContainer#create_service_container). Labels, not names, are how
    # dev tells its own containers from the user's: a name is an identity
    # Docker constrains to one token, a label is declared metadata.
    MANAGED_LABEL = "dev.managed"
    PROJECT_ROOT_LABEL = "dev.project_root"

    # One running container as `docker ps` reports it, with dev's label
    # contract decoded: a managed container names the checkout it serves;
    # anything else is the user's own and carries only its name.
    class RunningContainer < T::Struct
      extend T::Sig

      const :name, String
      const :managed, T::Boolean
      const :project_root, T.nilable(String)

      # One line for a human: a managed container is named by the checkout
      # it serves (that is where `dev container down` acts), the user's own
      # by its name, flagged as not dev's to manage.
      #
      # @param home [String] the home directory to abbreviate as `~`
      # @return [String]
      sig { params(home: String).returns(String) }
      def describe(home: Dir.home)
        root = project_root
        return "#{name} (not managed by dev)" if !managed || root.nil?

        shown = root.start_with?("#{home}/") ? root.sub("#{home}/", "~/") : root
        "#{File.basename(root)} (#{shown})"
      end
    end

    # @return [Symbol] :colima (the user's own VM), :docker (bare dockerd —
    #   whatever daemon the CLI's own context reaches), or :explicit (DOCKER_HOST)
    sig { returns(Symbol) }
    attr_reader :kind

    # @return [Array<String>] argv every docker invocation starts with
    sig { returns(T::Array[String]) }
    attr_reader :argv_prefix

    # @return [Hash{String => String}] extra env for every docker invocation
    #   (e.g. DOCKER_HOST pointing at the user's own colima socket)
    sig { returns(T::Hash[String, String]) }
    attr_reader :env

    class << self
      extend T::Sig

      # Resolve the invoking user's engine: an explicit DOCKER_HOST wins (the
      # docker CLI reads it from the inherited environment, so the engine adds
      # nothing) → the per-user settings record → the host OS's default
      # (colima on darwin, bare dockerd elsewhere). Empty strings count as
      # unset, matching Settings' layer semantics. A `docker` record is the
      # opt-out from the macOS default: bare docker with no env, which reaches
      # whatever daemon the CLI's own context does — unsupported but not
      # blocked (Docker Desktop users land here).
      #
      # @param settings [Dev::Settings] the invoking user's settings
      # @param env [Hash{String => String}] environment to consult (tests inject)
      # @param host_os [String] "darwin" / "linux" / "windows" (tests inject)
      # @return [Dev::ContainerEngine]
      # @raise [UnknownEngineError] when the record names an unshipped engine
      sig do
        params(settings: Dev::Settings, env: T::Hash[String, String], host_os: String).returns(ContainerEngine)
      end
      def resolve(settings: Dev::Settings.new, env: ENV.to_h, host_os: Dev::Deps.detect_host)
        docker_host = env["DOCKER_HOST"]
        return new(kind: :explicit) if docker_host && !docker_host.empty?

        record = settings.container_engine
        case record
        when nil then host_os == "darwin" ? colima : new(kind: :docker)
        when "docker" then new(kind: :docker)
        when "colima" then colima
        else
          raise UnknownEngineError,
            "unknown container_engine #{record.inspect} — dev ships \"colima\" and \"docker\"."
        end
      end

      # The invoking user's colima engine: bare docker pointed at the user's
      # own VM socket. Per-user by construction — the socket lives under the
      # caller's home, so the agent resolves its own engine from its own home
      # like it resolves its own $HOME.
      #
      # @return [Dev::ContainerEngine]
      sig { returns(ContainerEngine) }
      def colima
        socket = File.join(Dir.home, ".colima", COLIMA_PROFILE, "docker.sock")
        new(kind: :colima, env: { "DOCKER_HOST" => "unix://#{socket}" })
      end
    end

    # @param kind [Symbol] see #kind
    # @param argv_prefix [Array<String>] see #argv_prefix
    # @param env [Hash{String => String}] see #env
    sig { params(kind: Symbol, argv_prefix: T::Array[String], env: T::Hash[String, String]).void }
    def initialize(kind:, argv_prefix: ["docker"], env: {})
      @kind = kind
      @argv_prefix = argv_prefix
      @env = env
    end

    # Execute a docker invocation through this engine: the engine's env and
    # argv prefix, then the docker args. The engine is the executor boundary,
    # so tests fake it (recording argv) instead of stubbing Kernel#system —
    # the docker CLI is a true boundary.
    #
    # @param args [Array<String>] docker args after the prefix (e.g. ["pull", tag])
    # @param env [Hash{String => String}] per-call env merged over the engine's
    #   (e.g. DOCKER_BUILDKIT and build secrets)
    # @param opts [Hash] spawn options passed through (e.g. out:, err: File::NULL)
    # @return [Boolean] whether the invocation succeeded (nil collapses to false)
    sig { params(args: T::Array[String], env: T::Hash[String, String], opts: T.untyped).returns(T::Boolean) }
    def run(args, env: {}, **opts)
      !!T.unsafe(Kernel).system(@env.merge(env), *@argv_prefix, *args, **opts)
    end

    # Capture a docker invocation's stdout through this engine, discarding
    # stderr (probes double as existence checks; their misses are expected
    # noise, not errors worth surfacing). Best-effort by contract: a nonzero
    # exit or an unspawnable command reads as no output, so callers like cache
    # GC and stall probes degrade instead of raising.
    #
    # @param args [Array<String>] docker args after the prefix
    # @param env [Hash{String => String}] per-call env merged over the engine's
    # @return [String] the child's stdout ("" on failure)
    sig { params(args: T::Array[String], env: T::Hash[String, String]).returns(String) }
    def capture(args, env: {})
      stdout, _stderr, status = T.unsafe(Open3).capture3(@env.merge(env), *@argv_prefix, *args)
      status.success? ? stdout : ""
    rescue SystemCallError
      ""
    end

    # What the daemon behind this engine has to offer, read live from
    # `docker info` — the one inspection that works for every engine (a
    # colima VM, bare dockerd, an explicit DOCKER_HOST). This is the fact the
    # repo's `build.container.resources` minimum is checked against.
    #
    # @return [EngineResources, nil] nil when the daemon does not answer
    sig { returns(T.nilable(EngineResources)) }
    def resources
      out = capture(["info", "--format", "{{.NCPU}} {{.MemTotal}}"])
      cpus, memory = out.split
      return nil if cpus.nil? || memory.nil?

      EngineResources.from_bytes(cpus: Integer(cpus), memory_bytes: Integer(memory))
    rescue ArgumentError
      nil
    end

    # The containers running in this engine right now — the fact every
    # "is the engine idle?" decision rests on (`dev down`'s last-one-out stop,
    # `dev engine down`'s busy check, the provisioners' resize refusals). One
    # `docker ps` call; the label columns decode the dev contract so callers
    # can tell dev's own containers (stop them, name their checkout) from the
    # user's (ask first). Best-effort like every probe: a daemon that does not
    # answer reads as nothing running.
    #
    # @return [Array<RunningContainer>]
    sig { returns(T::Array[RunningContainer]) }
    def running_containers
      format = "{{.Names}}\t{{.Label \"#{MANAGED_LABEL}\"}}\t{{.Label \"#{PROJECT_ROOT_LABEL}\"}}"
      capture(["ps", "--format", format]).each_line.filter_map do |line|
        name, managed, project_root = line.chomp.split("\t", 3)
        next if name.nil? || name.empty?

        RunningContainer.new(
          name: name,
          managed: managed == "true",
          project_root: (project_root.nil? || project_root.empty?) ? nil : project_root,
        )
      end
    end

    # Whether dev may power this engine off when nothing is using it. True
    # for the engines dev provisions (its colima VM, the dockerd it converged);
    # false for an explicit DOCKER_HOST — that engine is the user's own,
    # possibly remote or shared, and dev never started it.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def idle_stoppable?
      @kind != :explicit
    end

    # Whether local paths bind-mounted into containers reach this engine's
    # daemon. True for every shipped engine (colima, bare dockerd, explicit
    # local DOCKER_HOST); the future remote engine answers false and brings
    # its sync strategy with it — mount call sites guard on this rather than
    # assume it.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def local_mounts?
      true
    end
  end
end
