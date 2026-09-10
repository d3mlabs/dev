# typed: strict
# frozen_string_literal: true

require "dev/settings"

module Dev
  # Which container engine docker invocations ride — the per-user container
  # substrate. Whether a repo's build runs containerized is a repo-shape
  # detail; *which daemon serves it* is a per-user provisioning decision, so
  # the engine is resolved from the invoking user's own config and injected
  # into everything that composes docker argv (BuildContainer, BuildWatcher,
  # CacheGc). The human rides Docker Desktop; the agent user rides its own
  # colima VM (Docker Desktop cannot serve a no-GUI user); a remote engine
  # later joins as config, never an architecture fork.
  #
  # Resolution order (see .resolve): explicit DOCKER_HOST in the caller's
  # environment → the per-user `container_engine` settings record → the
  # bare-docker default.
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

    # @return [Symbol] :docker_desktop, :colima, or :explicit (DOCKER_HOST)
    sig { returns(Symbol) }
    attr_reader :kind

    # @return [Array<String>] argv every docker invocation starts with
    sig { returns(T::Array[String]) }
    attr_reader :argv_prefix

    # @return [Hash{String => String}] extra env for every docker invocation
    #   (e.g. DOCKER_HOST pointing at the user's own colima socket)
    sig { returns(T::Hash[String, String]) }
    attr_reader :env

    # Resolve the invoking user's engine: an explicit DOCKER_HOST wins (the
    # docker CLI reads it from the inherited environment, so the engine adds
    # nothing) → the per-user settings record → the bare-docker default.
    # Empty strings count as unset, matching Settings' layer semantics.
    #
    # @param settings [Dev::Settings] the invoking user's settings
    # @param env [Hash{String => String}] environment to consult (tests inject)
    # @return [Dev::ContainerEngine]
    # @raise [UnknownEngineError] when the record names an unshipped engine
    sig { params(settings: Dev::Settings, env: T::Hash[String, String]).returns(ContainerEngine) }
    def self.resolve(settings: Dev::Settings.new, env: ENV.to_h)
      docker_host = env["DOCKER_HOST"]
      return new(kind: :explicit) if docker_host && !docker_host.empty?

      record = settings.container_engine
      case record
      when nil, "docker" then new(kind: :docker_desktop)
      when "colima" then colima
      else
        raise UnknownEngineError,
          "unknown container_engine #{record.inspect} — dev ships \"docker\" and \"colima\"."
      end
    end

    # The invoking user's colima engine: bare docker pointed at the user's
    # own VM socket. Per-user by construction — the socket lives under the
    # caller's home, so the agent resolves its own engine from its own home
    # like it resolves its own $HOME.
    #
    # @return [Dev::ContainerEngine]
    sig { returns(ContainerEngine) }
    def self.colima
      socket = File.join(Dir.home, ".colima", COLIMA_PROFILE, "docker.sock")
      new(kind: :colima, env: { "DOCKER_HOST" => "unix://#{socket}" })
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

    # Whether local paths bind-mounted into containers reach this engine's
    # daemon. True for every shipped engine (Docker Desktop, colima, explicit
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
