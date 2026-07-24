# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"

# Dev CLI: find repo with dev.yml, run declared commands (optionally in a CLI::UI Frame).
# Entry point: Dev::Runner.new.run(ARGV)
module Dev
  DEV_YAML_FILENAME = "dev.yml"

  class DevYamlNotFoundError < StandardError; end

  # Dev's root directory
  DEV_ROOT = T.let(Pathname.new(File.expand_path("..", __dir__)), Pathname)

  # Dev's lib directory
  DEV_LIB_DIR = T.let(DEV_ROOT / "lib", Pathname)

  class << self
    extend T::Sig

    # Pathname of dev.yml current working directory. Walks back parents until it finds a dev.yml file. Memoized on first call.
    sig { returns(Pathname) }
    def dev_yaml_file
      @dev_yaml_file = T.let(@dev_yaml_file, T.nilable(Pathname))
      return @dev_yaml_file if @dev_yaml_file

      result = T.let(nil, T.nilable(Pathname))
      Pathname.new(Dir.pwd).ascend do |path|
        dev_yaml_path = path / DEV_YAML_FILENAME
        if dev_yaml_path.exist?
          result = dev_yaml_path
          break
        end
      end
      raise DevYamlNotFoundError unless result

      @dev_yaml_file = result
    end

    # Target project root (directory containing dev.yml).
    #
    # Resolved lazily rather than as a load-time constant: requiring "dev" from
    # a directory without a dev.yml must not raise during load (it would dump a
    # backtrace before the CLI can print a friendly message). Callers that need
    # a project hit DevYamlNotFoundError here, where it can be handled.
    sig { returns(Pathname) }
    def target_project_root
      dev_yaml_file.dirname
    end
  end
end

require_relative "dev/command"
require_relative "dev/command_parser"
require_relative "dev/config"
require_relative "dev/config_parser"
require_relative "dev/cli"
require_relative "dev/command_runner"
require_relative "dev/runner"
