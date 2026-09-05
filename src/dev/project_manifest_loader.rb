# typed: strict
# frozen_string_literal: true

require "pathname"
require "yaml"
require "dev/deps"
require_relative "build_container_config"
require_relative "command_parser"
require_relative "project_manifest"
require_relative "runner_setup_config"

module Dev
  # The boundary coercion for a project's declaration files. Two passes,
  # each reading its file exactly once:
  #
  # - #load parses dev.yml (Runner construction) and rejects the removed
  #   `ruby:` key at parse time.
  # - #with_toolchain loads dependencies.rb, once per invocation as the
  #   ExecutionContext is assembled — help included, so dependencies.rb
  #   must stay cheap and side-effect-free (it is a declaration file).
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class ProjectManifestLoader
    extend T::Sig

    # Raised when dev.yml still carries the removed `ruby:` key. The
    # toolchain is a project dependency and is declared only in
    # dependencies.rb. RuntimeError so the CLI boundary reports it as a
    # clean `dev:` error.
    class UnsupportedDevYamlRubyError < RuntimeError; end

    # Host OS keys a `runner` block may be keyed by (one runner identity per
    # host OS — e.g. unreal-engine's linux build box vs mac editor builder).
    RUNNER_HOST_KEYS = T.let(%w[linux darwin].freeze, T::Array[String])

    sig { params(command_parser: CommandParser).void }
    def initialize(command_parser: CommandParser.new)
      @command_parser = command_parser
    end

    # Parse dev.yml into a manifest (toolchain fields left nil — see
    # #with_toolchain for the dependencies.rb pass).
    #
    # @param dev_yml_path [Pathname]
    # @return [ProjectManifest]
    # @raise [UnsupportedDevYamlRubyError] when dev.yml carries the removed
    #   `ruby:` key
    sig { params(dev_yml_path: Pathname).returns(ProjectManifest) }
    def load(dev_yml_path)
      yaml = YAML.load_file(dev_yml_path)
      reject_removed_ruby_key(yaml)
      raw_commands = yaml["commands"] || {}
      ProjectManifest.new(
        name: T.cast(yaml["name"], String),
        commands: raw_commands.transform_values { |h| @command_parser.parse(h) },
        build_container: parse_build_container(yaml),
        runner: parse_runner(yaml),
      )
    end

    # The dependencies.rb pass: load the deps manifest once and return a
    # manifest completed with the declared toolchain versions. A missing
    # dependencies.rb declares nothing; a broken one is reported as a
    # warning and treated the same — toolchain resolution then falls back
    # (e.g. to Homebrew Ruby), matching a project that declares no
    # toolchain. dev evaluates dependencies.rb under its own bootstrap Ruby,
    # so reading it here — before the project's interpreter is provisioned —
    # is safe.
    #
    # @param manifest [ProjectManifest] the dev.yml side from #load
    # @param project_root [Pathname] where dependencies.rb lives
    # @return [ProjectManifest]
    sig { params(manifest: ProjectManifest, project_root: Pathname).returns(ProjectManifest) }
    def with_toolchain(manifest, project_root:)
      deps_rb = project_root / "dependencies.rb"
      return manifest unless deps_rb.exist?

      # Reset first: a dependencies.rb that never calls Dev::Deps.define
      # (e.g. dev's own bootstrap-constants manifest) must not surface a
      # previously loaded project's config as its own.
      Dev::Deps.reset!
      Kernel.load(deps_rb.to_s)
      deps_config = Dev::Deps.last_config
      ProjectManifest.new(
        name: manifest.name,
        commands: manifest.commands,
        build_container: manifest.build_container,
        runner: manifest.runner,
        declared_ruby_version: presence(deps_config&.ruby_version_requirement),
        declared_python_version: presence(deps_config&.python_version),
      )
    rescue StandardError => e
      $stderr.puts "dev: could not read the toolchain from dependencies.rb (#{e.message})"
      manifest
    end

    private

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

    # Coerce a scalar to a non-empty String, or nil.
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
