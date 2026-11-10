# typed: false
# frozen_string_literal: true

require "dev/deps/ficsit_client"

# A FicsitClient that answers from a table instead of the wire — the one
# boundary the ficsit tests mock. Answers are keyed by the document's
# operation name (`GetModId`, `CreateVersion`, …); an answer is the `data`
# hash to return, or a Proc called with (variables, file) for an answer
# that depends on the call or changes between calls. Every call is
# recorded, so a test reads the sequence SMR would have seen. Each instance
# records only its own calls.
class FakeFicsitClient < Dev::Deps::FicsitClient
  # One call as it was made; `file` is nil for a plain query.
  Call = Data.define(:operation, :variables, :token, :file, :filename)

  attr_reader :calls

  # @param answers [Hash{String => Hash, Proc}] by operation name
  def initialize(answers)
    super()
    @answers = answers
    @calls = []
  end

  def query(document, variables, token: nil)
    answer(document, variables, token, nil, nil)
  end

  def upload(document, variables, file:, filename:, token:)
    answer(document, variables, token, file, filename)
  end

  # The calls of one operation, in order.
  #
  # @param operation [String]
  # @return [Array<Call>]
  def calls_of(operation)
    @calls.select { |call| call.operation == operation }
  end

  private

  def answer(document, variables, token, file, filename)
    operation = document[/\A\s*(?:query|mutation)\s+(\w+)/, 1]
    @calls << Call.new(operation:, variables:, token:, file:, filename:)
    answer = @answers.fetch(operation) { raise ArgumentError, "no answer scripted for #{operation}" }
    answer.respond_to?(:call) ? answer.call(variables, file) : answer
  end
end
