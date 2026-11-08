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

  DOWNLOAD = ["release", "download"].freeze

  def initialize(root: Pathname("/nonexistent/checkout"))
    super(root:)
    @answers = []
    @assets = Hash.new { |hash, tag| hash[tag] = {} }
    @calls = []
  end

  # The assets a tag's release serves to `gh release download`: each
  # `--pattern` asked for is written under `--dir` with these bytes, as gh
  # would; a pattern naming none is gh's refusal.
  #
  # @param tag [String] the tag's name (`v1.2.0`)
  # @param assets [Hash{String => String}] asset name → bytes
  # @return [FakeGh] self
  def serves(tag, assets)
    @assets[tag].merge!(assets)
    self
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
    return download(argv) if argv.first(DOWNLOAD.size) == DOWNLOAD

    index = @answers.index { |prefix, _out, _err| argv.first(prefix.size) == prefix }
    raise "FakeGh: nothing answers gh #{argv.join(" ")}" if index.nil?

    _prefix, out, err = @answers.delete_at(index)
    raise Dev::Lifecycle::Gh::CommandFailedError, "gh #{argv.join(" ")} failed in #{root}: #{err}" if err

    out
  end

  # The downloads asked of each tag so far, as asset names in argv order.
  #
  # @param tag [String]
  # @return [Array<Array<String>>] one entry per `gh release download` call
  def downloaded(tag)
    @calls.select { |call| call.argv.first(DOWNLOAD.size + 1) == DOWNLOAD + [tag] }
      .map { |call| call.argv.each_cons(2).filter_map { |flag, value| value if flag == "--pattern" } }
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

  private

  # `gh release download <tag> --dir D --clobber --pattern P…`: write each
  # served asset the patterns name into D, or refuse as gh does for a tag
  # with no release or a pattern matching no asset.
  #
  # @param argv [Array<String>]
  # @return [String] what gh prints: nothing
  def download(argv)
    tag = argv.fetch(2)
    raise Dev::Lifecycle::Gh::CommandFailedError, "gh #{argv.join(" ")} failed in #{root}: release not found" unless @assets.key?(tag)

    dir = Pathname(argv.fetch(argv.index("--dir") + 1))
    patterns = argv.each_cons(2).filter_map { |flag, value| value if flag == "--pattern" }
    patterns.each do |pattern|
      # The real gh matches a glob; dev escapes each name to match itself,
      # so the escape is undone to find the asset.
      name = pattern.gsub(/\\(.)/, '\1')
      bytes = @assets[tag][name]
      raise Dev::Lifecycle::Gh::CommandFailedError, "gh #{argv.join(" ")} failed in #{root}: no assets match the file pattern" if bytes.nil?

      (dir / name).binwrite(bytes)
    end
    ""
  end
end
