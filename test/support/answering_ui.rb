# typed: false
# frozen_string_literal: true

require "dev/cli/ui"
require "stringio"

# A terminal that answers every `confirm` as told, remembering each
# question with the default it was offered — the one double for a
# command whose test is about the question (dev#533). Everything else is
# `NoUi`: plain lines on `out`, no spinner, no router. Each instance keeps
# only its own questions, so tests share no state through it.
class AnsweringUi < Dev::Cli::NoUi
  # One `confirm` as it was asked.
  Question = Data.define(:text, :default)

  attr_reader :questions

  # @param out [IO, StringIO] where the plain lines go
  # @param answer [Boolean, nil] what every confirm answers (nil: no terminal)
  def initialize(out: StringIO.new, answer: false)
    super(out:)
    @answer = answer
    @questions = []
  end

  # @param question [String]
  # @param default [Boolean]
  # @return [Boolean, nil] the scripted answer
  def confirm(question, default: false)
    @questions << Question.new(text: question, default: default)
    @answer
  end

  # The questions' texts, for the common assertion.
  #
  # @return [Array<String>]
  def asked = @questions.map(&:text)
end
