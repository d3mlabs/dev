# typed: false
# frozen_string_literal: true

require "json"
require "pathname"
require "dev/lifecycle"

# A scripted stand-in for Dev::Lifecycle::Gh — the one true boundary of the
# deployment ledger, the forge behind it not reproducible in a temp dir.
# Answers are registered per argv prefix and consumed in order; every call
# is recorded (argv and the body piped to stdin) so a test asserts what
# dev asked the forge, not just what it got back. An argv nothing answers
# raises, so a test that forgot a step fails loudly instead of passing on
# nil.
class FakeGh < Dev::Lifecycle::Gh
  Call = Struct.new(:argv, :stdin, keyword_init: true)

  attr_reader :calls

  def initialize(root: Pathname("/nonexistent/checkout"))
    super(root:)
    @answers = []
    @calls = []
  end

  # @param prefix [Array<String>] the leading words of an argv this answers
  # @param stdout [String, Hash, Array] what gh prints (objects are JSON-encoded)
  # @return [FakeGh] self, for chaining
  def answers(prefix, with:)
    @answers << [prefix, with.is_a?(String) ? with : JSON.generate(with), nil]
    self
  end

  # @param prefix [Array<String>]
  # @param stderr [String] gh's complaint
  # @return [FakeGh] self
  def refuses(prefix, with:)
    @answers << [prefix, nil, with]
    self
  end

  # The repo gh resolves for the checkout, the first thing the ledger asks.
  def resolving(repo)
    answers(["repo", "view"], with: "#{repo}\n")
  end

  def capture(argv, stdin: nil)
    @calls << Call.new(argv:, stdin:)
    index = @answers.index { |prefix, _out, _err| argv.first(prefix.size) == prefix }
    raise "FakeGh: nothing answers gh #{argv.join(" ")}" if index.nil?

    _prefix, out, err = @answers.delete_at(index)
    raise Dev::Lifecycle::Gh::CommandFailedError, "gh #{argv.join(" ")} failed in #{root}: #{err}" if err

    out
  end

  # A streamed gh (`run watch`) consumes its scripted answer the same way;
  # what it would have printed goes nowhere, as the operator's terminal is
  # not under test.
  def stream(argv)
    capture(argv)
    nil
  end

  # The bodies dev posted, parsed, in call order.
  def posted
    @calls.select { |call| call.stdin }.map { |call| JSON.parse(call.stdin) }
  end

  # The API paths dev called, in order (the `repo view` excluded).
  def paths
    @calls.select { |call| call.argv.first == "api" }.map { |call| call.argv.last }
  end
end
