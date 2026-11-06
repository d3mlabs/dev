# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::VerbInvocationTest < Minitest::Test
  FETCH = Dev::Lifecycle::ArtifactFetch.new(name: "cellbound-3d-win64-dev", into: Pathname("/data/artifacts/cellbound-3d-win64-dev"))

  test "an invocation is the words after `dev`, spelled as one `verbs` entry, with what to bring back" do
    Given
    invocation = Dev::Lifecycle::VerbInvocation.new(words: ["package", "cellbound-3d-win64-dev", "--no-build"], fetch: FETCH)

    Expect
    invocation.verb == "package"
    invocation.words == ["package", "cellbound-3d-win64-dev", "--no-build"]
    invocation.to_s == "package cellbound-3d-win64-dev --no-build"
    invocation.fetch == FETCH
    Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"]).fetch.nil?
  end

  test "the words are the invocation's own: the array given is copied and frozen" do
    Given
    words = ["build", "x"]
    invocation = Dev::Lifecycle::VerbInvocation.new(words:)

    When
    words << "--runner"

    Then
    invocation.words == ["build", "x"]
    invocation.words.frozen?
    invocation.frozen?
  end

  test "a word that cannot cross whole is refused: #{word.inspect}" do
    When
    Dev::Lifecycle::VerbInvocation.new(words: ["build", word])

    Then
    error = raises(Dev::Lifecycle::VerbInvocation::UnspeakableWordError)
    error.message == "#{word.inspect} cannot cross to a remote host as one word (no commas, no whitespace, not empty)"

    Where
    word
    ""
    "a,b"
    "a b"
    "a\tb"
    "a\nb"
  end

  test "no words is no verb" do
    When
    Dev::Lifecycle::VerbInvocation.new(words: [])

    Then
    raises Dev::Lifecycle::VerbInvocation::EmptyInvocationError
  end

  test "invocations compare by words and fetch" do
    Given
    a = Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])
    same = Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])
    fetching = Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"], fetch: FETCH)

    Expect
    a == same
    a.eql?(same)
    a.hash == same.hash
    a != fetching
    a != Dev::Lifecycle::VerbInvocation.new(words: ["build", "y"])
    a != "build x"
  end
end
