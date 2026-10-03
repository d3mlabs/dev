# typed: strict
# frozen_string_literal: true

require "stringio"

module Dev
  # A yes/no question at the terminal, for the one kind of step dev will
  # not take unasked: acting on something it does not manage (stopping the
  # user's own containers so the engine can go down). Off a terminal the
  # answer is no — a script cannot consent, and `--force` is how it says yes
  # up front. Injectable so command tests script the answer instead of
  # touching stdin.
  class Confirmer
    extend T::Sig

    # @param input [IO, StringIO] where the answer comes from
    # @param out [IO, StringIO] where the question goes (stderr: it is
    #   dialogue, not the command's payload)
    sig { params(input: T.any(IO, StringIO), out: T.any(IO, StringIO)).void }
    def initialize(input: $stdin, out: $stderr)
      @input = input
      @out = out
    end

    # Ask. Anything but a leading y/Y — including an empty line and end of
    # input — is no.
    #
    # @param question [String] the question, without the [y/N] cue
    # @return [Boolean] whether the user said yes
    sig { params(question: String).returns(T::Boolean) }
    def confirm?(question)
      return false unless @input.tty?

      @out.print("#{question} [y/N] ")
      answer = @input.gets
      !answer.nil? && answer.strip.downcase.start_with?("y")
    end
  end
end
