# typed: strict
# frozen_string_literal: true

require_relative "build_container_config"
require_relative "runner_setup_config"

module Dev
  # Value object for parsed dev.yml: repo name and command specs.
  class Config
    extend T::Sig

    sig { returns(String) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :ruby_version

    sig { returns(T.nilable(BuildContainerConfig)) }
    attr_reader :build_container

    sig { returns(T.nilable(RunnerSetupConfig)) }
    attr_reader :runner

    sig do
      params(
        name: String,
        commands: T::Hash[String, ShellCommand],
        ruby_version: T.nilable(String),
        build_container: T.nilable(BuildContainerConfig),
        runner: T.nilable(RunnerSetupConfig),
      ).void
    end
    def initialize(name:, commands:, ruby_version: nil, build_container: nil, runner: nil)
      @name = T.let(name, String)
      @commands = T.let(commands.freeze, T::Hash[String, ShellCommand])
      @ruby_version = T.let(ruby_version, T.nilable(String))
      @build_container = T.let(build_container, T.nilable(BuildContainerConfig))
      @runner = T.let(runner, T.nilable(RunnerSetupConfig))
    end

    # Project commands defined in dev.yml.
    #
    # @return [Hash{String => ShellCommand}]
    sig { returns(T::Hash[String, ShellCommand]) }
    def commands
      @commands
    end

    sig { params(out: T.any(IO, StringIO)).void }
    def print_usage(out: $stdout)
      out.puts "Usage: dev <command> [args...]"
      out.puts ""
      out.puts "Commands for #{name}:"
      if @commands.empty?
        out.puts "  (no commands defined in dev.yml)"
      else
        @commands.each do |cmd_name, command|
          out.puts "  #{cmd_name.ljust(12)} #{command.desc}"
        end
      end
      out.puts ""
      out.puts "Examples: dev up    dev up -v    dev update-deps    dev test"
    end
  end
end
