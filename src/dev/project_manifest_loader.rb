# typed: strict
# frozen_string_literal: true

require "pathname"
require "yaml"
require "dev/engine_resources"
require_relative "build_container_config"
require_relative "command_parser"
require_relative "project_manifest"

module Dev
  # The boundary coercion for dev.yml: #load parses it once and rejects the
  # removed `ruby:` key at parse time. dependencies.rb is not read here —
  # the toolchain is a dependency, and only the deps commands evaluate that
  # file.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ProjectManifestLoader
    extend T::Sig

    # Raised when dev.yml still carries the removed `ruby:` key. The
    # toolchain is a project dependency and is declared only in
    # dependencies.rb. RuntimeError so the CLI boundary reports it as a
    # clean `dev:` error.
    class UnsupportedDevYamlRubyError < RuntimeError; end

    # Raised when dev.yml sizes the engine twice: the top-level `engine:`
    # block and the legacy `build.container.resources` (d3mlabs/dev#311).
    # One floor per project; dev does not pick.
    class ConflictingEngineHintError < RuntimeError; end

    sig { params(command_parser: CommandParser).void }
    def initialize(command_parser: CommandParser.new)
      @command_parser = command_parser
    end

    # Parse dev.yml into a manifest.
    #
    # @param dev_yml_path [Pathname]
    # @return [ProjectManifest]
    # @raise [UnsupportedDevYamlRubyError] when dev.yml carries the removed
    #   `ruby:` key
    # @raise [ConflictingEngineHintError] when the engine is sized in both
    #   `engine:` and `build.container.resources`
    sig { params(dev_yml_path: Pathname).returns(ProjectManifest) }
    def load(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      reject_removed_ruby_key(yaml)
      warn_retired_runner_key(yaml)
      raw_commands = yaml["commands"] || {}
      ProjectManifest.new(
        name: T.cast(yaml["name"], String),
        commands: raw_commands.to_h { |name, h| [name.to_s, @command_parser.parse([name.to_s], h)] },
        engine: parse_engine(yaml),
        build_container: parse_build_container(yaml),
      )
    end

    # `ruby:` is a removed dev.yml key — rejected at parse time with a
    # dependencies.rb migration message instead of silently ignoring it.
    #
    # @param yaml [Hash]
    # @return [void]
    # @raise [UnsupportedDevYamlRubyError]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def reject_removed_ruby_key(yaml)
      ruby_version = yaml["ruby"]&.to_s
      return if ruby_version.nil? || ruby_version.empty?

      raise UnsupportedDevYamlRubyError,
        "dev.yml `ruby:` is no longer supported; declare the toolchain in dependencies.rb: " \
          'Dev::Deps.define { ruby "x.y.z" }'
    end

    # `runner:` is a retired dev.yml key — enrollment identity is a machine
    # fact, not a repo declaration: the repo label derives from the repo name
    # and everything else is flags (`dev runner register`). A warning, not an
    # error: the block simply means nothing now, and existing enrollments
    # keep working untouched.
    #
    # @param yaml [Hash]
    # @return [void]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def warn_retired_runner_key(yaml)
      return unless yaml.key?("runner")

      $stderr.puts "dev: dev.yml `runner:` is retired and ignored — the repo runner label now derives " \
                   "from the repo name (`dev runner register`); delete the block."
    end

    sig { params(yaml: T::Hash[String, T.untyped]).returns(T.nilable(BuildContainerConfig)) }
    def parse_build_container(yaml)
      build = yaml["build"]
      return nil unless build.is_a?(Hash)

      container = build["container"]
      return nil unless container.is_a?(Hash)

      # image/registry name a hand-written-Dockerfile image (deprecated,
      # d3mlabs/dev#311); a block without them shapes the container around
      # the lock's image pin (dev#277).
      image = presence(container["image"])
      registry = presence(container["registry"])

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

    # @param raw [Object, nil] a scalar dev.yml value
    # @return [String, nil] its string form, nil when absent or blank
    sig { params(raw: T.untyped).returns(T.nilable(String)) }
    def presence(raw)
      value = raw&.to_s
      value.nil? || value.empty? ? nil : value
    end

    # The engine floor: the top-level `engine:` block, or — until
    # d3mlabs/dev#311 — the legacy `build.container.resources`, the same
    # three fields in the old place. Never both.
    #
    # @param yaml [Hash]
    # @return [EngineResources::Hint, nil]
    # @raise [ConflictingEngineHintError]
    sig { params(yaml: T::Hash[String, T.untyped]).returns(T.nilable(EngineResources::Hint)) }
    def parse_engine(yaml)
      engine = yaml["engine"]
      legacy = yaml.dig("build", "container", "resources")
      if engine.is_a?(Hash) && legacy.is_a?(Hash)
        raise ConflictingEngineHintError,
          "dev.yml sizes the engine in both `engine:` and `build.container.resources`; keep `engine:` " \
            "(the `resources` key goes with d3mlabs/dev#311)"
      end

      parse_resources(engine.is_a?(Hash) ? engine : legacy)
    end

    # Coerce the optional resources sizing block to integers at the parse
    # boundary; a missing or non-hash block is no hint at all.
    #
    # @param raw [Object, nil] the block as YAML gave it
    # @return [EngineResources::Hint, nil]
    sig { params(raw: T.untyped).returns(T.nilable(EngineResources::Hint)) }
    def parse_resources(raw)
      return nil unless raw.is_a?(Hash)

      cpus = raw["cpus"]
      memory_gib = raw["memory_gib"]
      disk_gib = raw["disk_gib"]
      EngineResources::Hint.new(
        cpus: cpus.nil? ? nil : Integer(cpus),
        memory_gib: memory_gib.nil? ? nil : Integer(memory_gib),
        disk_gib: disk_gib.nil? ? nil : Integer(disk_gib),
      )
    end
  end
end
