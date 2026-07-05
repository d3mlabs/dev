# typed: strict
# frozen_string_literal: true

require "yaml"
require_relative "command_parser"
require_relative "build_container_config"
require_relative "runner_setup_config"
require "pathname"

module Dev
  # Parses dev.yml into a Config object.
  class ConfigParser
    extend T::Sig
    extend T::Helpers

    sig { params(command_parser: CommandParser).void }
    def initialize(command_parser:)
      @command_parser = T.let(command_parser, CommandParser)
    end

    sig { params(dev_yml_path: Pathname).returns(Config) }
    def parse(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      raw_commands = yaml["commands"] || {}
      commands = raw_commands.transform_values { |h| @command_parser.parse(h) }
      ruby_version = yaml["ruby"]&.to_s
      ruby_version = nil if ruby_version&.empty?
      build_container = parse_build_container(yaml)
      runner = parse_runner(yaml)
      Config.new(
        name: T.cast(yaml["name"], String),
        commands: commands,
        ruby_version: ruby_version,
        build_container: build_container,
        runner: runner,
      )
    end

    private

    # Host OS keys a `runner` block may be keyed by (one runner identity per
    # host OS — e.g. unreal-engine's linux build box vs mac editor builder).
    RUNNER_HOST_KEYS = T.let(%w[linux darwin].freeze, T::Array[String])

    # Parse the top-level `runner` block into a RunnerSetupConfig. Returns nil
    # when absent or labelless (labels are what make a runner registration
    # meaningful). labels accept a string or a YAML list, normalized to the
    # comma-separated form config.sh expects.
    #
    # Two shapes: a flat block (one identity for any host), or a host-keyed
    # block (`runner: { linux: {...}, darwin: {...} }`) where `dev runner-setup`
    # registers the identity matching the current host OS — and doesn't exist
    # on hosts without one.
    sig { params(yaml: T::Hash[String, T.untyped]).returns(T.nilable(RunnerSetupConfig)) }
    def parse_runner(yaml)
      runner = yaml["runner"]
      return nil unless runner.is_a?(Hash)

      runner = runner[current_host_key] if host_keyed_runner?(runner)
      return nil unless runner.is_a?(Hash)

      labels = Array(runner["labels"]).map(&:to_s).reject(&:empty?).join(",")
      return nil if labels.empty?

      RunnerSetupConfig.new(
        labels: labels,
        dir: presence(runner["dir"]),
        name: presence(runner["name"]),
        version: presence(runner["version"]),
      )
    end

    # A runner block is host-keyed when any top-level key is a host OS name.
    sig { params(runner: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def host_keyed_runner?(runner)
      runner.keys.any? { |key| RUNNER_HOST_KEYS.include?(key.to_s) }
    end

    sig { returns(String) }
    def current_host_key
      RUBY_PLATFORM.include?("darwin") ? "darwin" : "linux"
    end

    # Coerce a YAML scalar to a non-empty String, or nil.
    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def presence(value)
      str = value&.to_s
      str unless str.nil? || str.empty?
    end

    sig { params(yaml: T::Hash[String, T.untyped]).returns(T.nilable(BuildContainerConfig)) }
    def parse_build_container(yaml)
      build = yaml["build"]
      return nil unless build.is_a?(Hash)

      container = build["container"]
      return nil unless container.is_a?(Hash)

      image = container["image"]&.to_s
      registry = container["registry"]&.to_s
      return nil if image.nil? || image.empty? || registry.nil? || registry.empty?

      volumes = Array(container["volumes"]).map(&:to_s)
      build_args = (container["build_args"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
      build_secrets = (container["build_secrets"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
      run_env = (container["run_env"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
      content_globs = Array(container["content_globs"]).map(&:to_s)
      structure_globs = Array(container["structure_globs"]).map(&:to_s)
      prewarm = container["prewarm"]&.to_s
      prewarm = nil if prewarm&.empty?
      persist = container["persist"] == true
      BuildContainerConfig.new(
        image: image, registry: registry, volumes: volumes,
        build_args: build_args, build_secrets: build_secrets,
        run_env: run_env, content_globs: content_globs,
        structure_globs: structure_globs, prewarm: prewarm,
        persist: persist,
      )
    end
  end
end
