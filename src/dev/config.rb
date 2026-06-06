# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for parsed dev.yml: repo name and command specs.
  class Config
    extend T::Sig

    sig { returns(String) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :ruby_version

    sig { params(name: String, commands: T::Hash[String, ShellCommand], ruby_version: T.nilable(String)).void }
    def initialize(name:, commands:, ruby_version: nil)
      @name = T.let(name, String)
      @commands = T.let(commands.freeze, T::Hash[String, ShellCommand])
      @ruby_version = T.let(ruby_version, T.nilable(String))
    end

    # Returns the project commands hash for merging into the registry.
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
