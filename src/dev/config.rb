# typed: strict
# frozen_string_literal: true

module Dev
  # Value object for parsed dev.yml: repo name and command specs.
  class Config
    extend T::Sig

    sig { returns(String) }
    attr_reader :name


    sig { params(name: String, commands: T::Hash[String, Command]).void }
    def initialize(name:, commands:)
      @name = T.let(name, String)
      @commands = T.let(commands.freeze, T::Hash[String, Command])
    end

    sig { params(name: String).returns(Command) }
    def command(name)
      @commands.fetch(name)
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
