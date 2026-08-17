# typed: strict
# frozen_string_literal: true

module Dev
  module Cli
    # Parses `--flag value` / `--flag=value` pairs out of a command's argv.
    # Stateless — the small shared helper behind the builtins that take
    # value flags (cache's --keep, runner-setup's --repo/--labels/--dir/--name).
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
    end
  end
end
