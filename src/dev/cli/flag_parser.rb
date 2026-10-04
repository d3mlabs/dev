# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # Parses `--flag value` / `--flag=value` pairs out of a command's argv.
    # Stateless — the small shared helper behind the builtins that take
    # value flags (cache's --keep, runner register's --repo/--labels/--dir/--name).
    class FlagParser
      extend T::Sig

      # The value of `--flag value` or `--flag=value`, or nil when absent.
      #
      # @param args [Array<String>]
      # @param flag [String] the flag including its dashes, e.g. "--keep"
      # @return [String, nil]
      sig { params(args: T::Array[String], flag: String).returns(T.nilable(String)) }
      def value(args, flag)
        idx = args.index(flag)
        return args[idx + 1] if idx && args[idx + 1]

        inline = args.find { |a| a.start_with?("#{flag}=") }
        inline&.split("=", 2)&.fetch(1)
      end

      # Every value of a repeatable flag, in argv order, mixing both forms
      # (`--group build --group=test` → ["build", "test"]). A trailing
      # valueless occurrence contributes nothing.
      #
      # @param args [Array<String>]
      # @param flag [String] the flag including its dashes, e.g. "--group"
      # @return [Array<String>] empty when the flag never appears
      sig { params(args: T::Array[String], flag: String).returns(T::Array[String]) }
      def values(args, flag)
        args.each_with_index.filter_map do |arg, idx|
          if arg == flag
            args[idx + 1]
          elsif arg.start_with?("#{flag}=")
            arg.split("=", 2).fetch(1)
          end
        end
      end
    end
  end
end
