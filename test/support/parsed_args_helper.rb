# typed: false
# frozen_string_literal: true

require "dev/cli/flag_vocabulary"
require "dev/cli/parsed_args"

# Builds the args a builtin receives in production — its own flag
# vocabulary applied to the words — so a test drives `call` through the
# same parse the service does:
#
#   command.call(args: parsed_args(command, ["--keep", "3"]), context:)
#   command.call(args: no_args, context:)
module ParsedArgsHelper
  # @param command [Dev::Command] the builtin whose vocabulary applies
  # @param words [Array<String>] the argv after the command's path
  # @return [Dev::Cli::ParsedArgs]
  def parsed_args(command, words)
    Dev::Cli::FlagVocabulary.new.parse(command, path: [], args: words)
  end

  # @return [Dev::Cli::ParsedArgs] an empty argv, parsed
  def no_args
    Dev::Cli::ParsedArgs.new
  end
end
