# typed: strict
# frozen_string_literal: true

require "pathname"
require "yaml"
require "dev/engine_resources"
require_relative "command_parser"
require_relative "project_manifest"

module Dev
  # The boundary coercion for dev.yml: #load parses it once and rejects the
  # removed keys at parse time — `ruby:`, and the Dockerfile path's
  # `build.container` block with every command's `container:` flag
  # (dev#307, dev#311), each with where it went. dependencies.rb is not
  # read here — the toolchain is a dependency, and only the deps commands
  # evaluate that file.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ProjectManifestLoader
    extend T::Sig

    # Raised when dev.yml still carries the removed `ruby:` key. The
    # toolchain is a project dependency and is declared only in
    # dependencies.rb. RuntimeError so the CLI boundary reports it as a
    # clean `dev:` error.
    class UnsupportedDevYamlRubyError < RuntimeError; end

    # Raised when dev.yml still carries the Dockerfile path's keys: the
    # `build.container` block, a command's `container:` flag. The
    # environment is the lock's `image` block (dev#277); the message lists
    # each key with its migration. RuntimeError so the CLI boundary reports
    # it as a clean `dev:` error.
    class RetiredKeysError < RuntimeError; end

    # What each key of the retired `build.container` block became.
    BLOCK_KEY_MIGRATIONS = T.let(
      {
        "image" => "delete it — the image is the lock's `image` pin",
        "registry" => "delete it — `registry:` on the `image` block, if not the floor's",
        "persist" => "`persist true` in the `image` block",
        "volumes" => "`volume \"…\"` lines in the `image` block",
        "run_env" => "`run_env \"VAR\" => \"ns/key\"` lines in the `image` block",
        "resources" => "`engine:` at the top level of dev.yml",
      }.freeze,
      T::Hash[String, String],
    )
    # The block's keys that fed the Dockerfile build and have no successor.
    GONE_WITH_THE_DOCKERFILE = "delete it — the Dockerfile path is gone (d3mlabs/dev#311)"

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
    # @raise [RetiredKeysError] when dev.yml carries `build.container` or a
    #   command's `container:` flag
    sig { params(dev_yml_path: Pathname).returns(ProjectManifest) }
    def load(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      reject_removed_ruby_key(yaml)
      reject_retired_keys(yaml)
      warn_retired_runner_key(yaml)
      raw_commands = yaml["commands"] || {}
      ProjectManifest.new(
        name: T.cast(yaml["name"], String),
        commands: raw_commands.to_h { |name, h| [name.to_s, @command_parser.parse([name.to_s], h)] },
        engine: parse_resources(yaml["engine"]),
      )
    end

    # The Dockerfile path's keys are refused before any command exists:
    # the `build.container` block (each key it carries, with where it
    # went) and every command's `container:` flag, nested commands
    # included — in document order, one message.
    #
    # @param yaml [Hash]
    # @return [void]
    # @raise [RetiredKeysError]
    sig { params(yaml: T::Hash[String, T.untyped]).void }
    def reject_retired_keys(yaml)
      lines = []
      block = yaml.dig("build", "container")
      lines.concat(block_migrations(block)) if block.is_a?(Hash)
      lines.concat(container_flag_migrations(["commands"], yaml["commands"]))
      return if lines.empty?

      raise RetiredKeysError,
        "dev.yml carries the retired Dockerfile path's keys — declare an `image` block in dependencies.rb " \
          "(d3mlabs/dev#277) and migrate each (dev#307, dev#311):\n  #{lines.join("\n  ")}"
    end

    # @param block [Hash] the `build.container` mapping
    # @return [Array<String>] a line per key the block carries; one for an empty block
    sig { params(block: T::Hash[T.untyped, T.untyped]).returns(T::Array[String]) }
    def block_migrations(block)
      lines = block.keys.map do |key|
        "build.container.#{key} → #{BLOCK_KEY_MIGRATIONS.fetch(key.to_s, GONE_WITH_THE_DOCKERFILE)}"
      end
      lines.empty? ? ["build.container → delete the block"] : lines
    end

    # @param path [Array<String>] the dev.yml path of this `commands:` mapping
    # @param raw [Object] its value as YAML delivered it
    # @return [Array<String>] a migration line per `container:` flag under it, deepest last
    sig { params(path: T::Array[String], raw: T.untyped).returns(T::Array[String]) }
    def container_flag_migrations(path, raw)
      return [] unless raw.is_a?(Hash)

      raw.flat_map do |name, entry|
        next [] unless entry.is_a?(Hash)

        entry_path = path + [name.to_s]
        own = []
        if entry.key?("container")
          value = entry["container"]
          went = value == false ? "`runs_on: #{ProjectCommand::HOST}`" : "delete it (the image's name under `runs_on:`, or nothing)"
          own << "#{(entry_path + ["container"]).join(".")}: #{value.inspect} → #{went}"
        end
        own + container_flag_migrations(entry_path + ["commands"], entry["commands"])
      end
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

    # The engine floor, the top-level `engine:` block, coerced to integers
    # at the parse boundary; a missing or non-hash block is no hint at all.
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
