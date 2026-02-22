# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

# Dev CLI: find repo with dev.yml, run declared commands (optionally in a CLI::UI Frame).
# Entry point: Dev::Runner.new.run(ARGV)
module Dev
  extend T::Sig

  DEV_YAML_FILENAME = T.let("dev.yml".freeze, String)
  GIT_ROOT_COMMAND = T.let("git rev-parse --show-toplevel 2>/dev/null".freeze, String)

  # Full path to dev.yml at git root (from Dir.pwd). Memoized on first call.
  sig { returns(String) }
  def self.resolve_dev_yaml_path
    @dev_yml_path ||= T.let(begin
        root = Dir.chdir(Dir.pwd) { `#{GIT_ROOT_COMMAND}`.strip }
        raise "not inside a git repository" if root.empty?
        root = File.expand_path(root)
        path = File.join(root, DEV_YAML_FILENAME)
        raise "no #{DEV_YAML_FILENAME} at git root (#{root})" unless File.file?(path)
        path.freeze
      end,
      T.nilable(String)
    )
  end

  DEV_YAML_PATH = T.let(resolve_dev_yaml_path.freeze, String)
end

require_relative "dev/command"
require_relative "dev/command_parser"
require_relative "dev/config"
require_relative "dev/config_parser"
require_relative "dev/cli"
require_relative "dev/command_runner"
require_relative "dev/runner"
