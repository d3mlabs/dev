# typed: strict
# frozen_string_literal: true

require "dev/build_container_config"
require "dev/container_engine"
require "dev/engine_resources"
require "dev/settings"
require "stringio"

module Dev
  # The read-only gate between a repo's build.container.resources hint and
  # the engine a containerized command is about to use: what the daemon
  # reports (ContainerEngine#resources) against what the repo declared it
  # needs (BuildContainerConfig::Resources). Runs at `dev up` after the engine
  # is provisioned and again at every image resolution, so a VM that shrank
  # underneath a project — or was never resized — fails before a 40-minute
  # build does, silently, on half the cores it was tuned for.
  #
  # Never resizes: sizing is ColimaProvisioner's job, and only `dev up` may
  # stop a VM. The check decides between two outcomes per the
  # `engine_resources` setting — `enforce` (default) raises a typed error
  # whose message says how to fix it for this engine kind; `warn` prints the
  # same shortfall and lets the command continue, naming the layer that
  # switched enforcement off so nobody wonders why a hard fail went soft.
  class EngineResourcesCheck
    extend T::Sig

    # The engine has fewer cpus or less memory than the repo's hint declares.
    class UndersizedEngineError < RuntimeError; end

    # Appended to the enforce-mode failure only: in warn mode the hatch is
    # already open.
    ESCAPE_HATCH = "Set `engine_resources: warn` (or DEV_ENGINE_RESOURCES=warn) to build undersized anyway."

    # @param settings [Dev::Settings] carries the engine_resources mode
    # @param out [IO] where the warn-mode notice goes
    sig { params(settings: Dev::Settings, out: T.any(IO, StringIO)).void }
    def initialize(settings: Dev::Settings.new, out: $stderr)
      @settings = settings
      @out = out
    end

    # Compare the engine to the hint and act per the setting.
    #
    # An unreachable daemon (no resources answer) is not a shortfall: the
    # docker call that follows will report that failure in its own words.
    #
    # @param engine [Dev::ContainerEngine] the engine the command will use
    # @param hint [BuildContainerConfig::Resources, nil] the repo's minimum; nil requires nothing
    # @param actual [EngineResources, nil] the engine's size when the caller knows it better than
    #   `docker info` does (a WSL2 VM's daemon reports what its kernel kept, not what WSL gave the VM);
    #   nil asks the daemon
    # @return [void]
    # @raise [UndersizedEngineError] in enforce mode, when the engine falls short
    # @raise [Settings::InvalidSettingError] on an unknown engine_resources value
    sig do
      params(
        engine: Dev::ContainerEngine,
        hint: T.nilable(BuildContainerConfig::Resources),
        actual: T.nilable(EngineResources),
      ).void
    end
    def check!(engine:, hint:, actual: nil)
      return if hint.nil? || (hint.cpus.nil? && hint.memory_gib.nil?)

      actual ||= engine.resources
      return if actual.nil? || actual.satisfies?(hint)

      message = shortfall_message(engine, actual, hint)
      mode = @settings.engine_resources
      raise UndersizedEngineError, "#{message} #{ESCAPE_HATCH}" if mode == "enforce"

      @out.puts "dev: warning: #{message}"
      @out.puts "dev: engine_resources: warn (#{@settings.lookup('engine_resources').last} config) — continuing on the undersized engine."
    end

    private

    # @param engine [Dev::ContainerEngine]
    # @param actual [EngineResources] what the daemon reports
    # @param hint [BuildContainerConfig::Resources] what the repo declared
    # @return [String] the shortfall plus the fix for this engine kind
    sig do
      params(engine: Dev::ContainerEngine, actual: EngineResources, hint: BuildContainerConfig::Resources)
        .returns(String)
    end
    def shortfall_message(engine, actual, hint)
      "the #{engine_label(engine)} has #{actual}; this project needs #{hint_to_s(hint)}. #{remedy(engine)}"
    end

    # @param engine [Dev::ContainerEngine]
    # @return [String]
    sig { params(engine: Dev::ContainerEngine).returns(String) }
    def engine_label(engine)
      case engine.kind
      when :colima then "colima VM"
      when :explicit then "engine at DOCKER_HOST"
      else "docker engine"
      end
    end

    # @param engine [Dev::ContainerEngine]
    # @return [String] how to close the gap on this kind of engine
    sig { params(engine: Dev::ContainerEngine).returns(String) }
    def remedy(engine)
      case engine.kind
      when :colima
        "Run `dev up` to resize the VM (it stops and restarts an idle VM; when other projects' " \
          "containers are running it names them and refuses)."
      when :explicit
        "That engine is yours to resize."
      else
        "Run `dev up`: on WSL2 it raises `processors` / `memory` in %USERPROFILE%\\.wslconfig and tells you " \
          "when to `wsl --shutdown`; on Linux the daemon already has the whole machine."
      end
    end

    # @param hint [BuildContainerConfig::Resources]
    # @return [String] the declared fields only, e.g. "12 cpus / 24 GiB" or "24 GiB"
    sig { params(hint: BuildContainerConfig::Resources).returns(String) }
    def hint_to_s(hint)
      parts = []
      parts << "#{hint.cpus} cpus" if hint.cpus
      parts << "#{hint.memory_gib} GiB" if hint.memory_gib
      parts.join(" / ")
    end
  end
end
