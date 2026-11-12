# typed: false
# frozen_string_literal: true

require "stringio"
require "support/recording_ui"

# A terminal that answers every `confirm` and every `ask_secret` as told,
# remembering each question (and the default a confirm was offered) — the
# one double for a command whose test is about the question (dev#533). The
# secret itself is never recorded, only that it was asked for. Everything
# else is `RecordingUi`: what was said around the question is on `rows`,
# plain lines on `out`, no spinner, no router. Each instance keeps only
# its own questions, so tests share no state through it.
class AnsweringUi < RecordingUi
  # One `confirm` as it was asked.
  Question = Data.define(:text, :default)

  attr_reader :questions, :secrets_asked

  # @param out [IO, StringIO] where the plain lines go
  # @param answer [Boolean, nil] what every confirm answers (nil: no terminal)
  # @param secret [String, nil] what every ask_secret answers (nil: no terminal)
  def initialize(out: StringIO.new, answer: false, secret: nil)
    super(out:)
    @answer = answer
    @secret = secret
    @questions = []
    @secrets_asked = []
  end

  # @param question [String]
  # @param default [Boolean]
  # @return [Boolean, nil] the scripted answer
  def confirm(question, default: false)
    @questions << Question.new(text: question, default: default)
    @answer
  end

  # @param question [String]
  # @return [String, nil] the scripted secret
  def ask_secret(question)
    @secrets_asked << question
    @secret
  end

  # The questions' texts, for the common assertion.
  #
  # @return [Array<String>]
  def asked
    @questions.map(&:text)
  end
end
