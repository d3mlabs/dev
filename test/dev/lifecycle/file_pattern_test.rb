# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::FilePatternTest < Minitest::Test
  PATTERN = Dev::Lifecycle::FilePattern

  test "gitignore syntax over a stage path: #{source.inspect} against #{path}" do
    Expect
    PATTERN.new(source: source).matches?(Pathname(path)) == matches

    Where
    source           | path                     | matches
    # a bare name matches at any depth, a directory through its contents
    "bin"            | "bin/dev"                | true
    "bin"            | "bin/sub/tool"           | true
    "bin"            | "lib/bin/x"              | true
    "bin"            | "bin"                    | true
    "bin"            | "binary"                 | false
    "bin"            | "lib/dev.rb"             | false
    "VERSION"        | "VERSION"                | true
    "VERSION"        | "lib/VERSION"            | true
    # a slash at the start or in the middle anchors at the stage root
    "/bin"           | "bin/dev"                | true
    "/bin"           | "lib/bin/x"              | false
    "deploy/d3mlabs" | "deploy/d3mlabs/Brewfile" | true
    "deploy/d3mlabs" | "other/deploy/d3mlabs/x" | false
    "lib/dev.rb"     | "lib/dev.rb"             | true
    # a trailing slash matches directories only
    "bin/"           | "bin/dev"                | true
    "bin/"           | "bin"                    | false
    "lib/"           | "lib/dev.rb"             | true
    # globs: * stops at /, ** spans directories, * matches a leading dot
    "*.md"           | "README.md"              | true
    "*.md"           | "docs/x.md"              | true
    "/*.md"          | "docs/x.md"              | false
    "lib/*.rb"       | "lib/dev.rb"             | true
    "lib/*.rb"       | "lib/dev/cli.rb"         | false
    "lib/**/*.rb"    | "lib/dev/cli.rb"         | true
    "lib/**"         | "lib/dev/cli/x.rb"       | true
    "**/fixtures"    | "test/a/fixtures/x"      | true
    "*"              | ".gitignore"             | true
    "?ib"            | "lib/x"                  | true
    # negation and the escaped bang
    "!lib"           | "lib/dev.rb"             | true
    "\\!important"   | "!important"             | true
    "\\!important"   | "important"              | false
  end

  test "a leading ! marks the pattern negated and nothing else" do
    Expect
    PATTERN.new(source: "!lib").negated?
    !PATTERN.new(source: "lib").negated?
    !PATTERN.new(source: "\\!lib").negated?
    PATTERN.new(source: "!lib").to_s == "!lib"
  end

  test "a pattern with nothing to match is refused: #{source.inspect}" do
    When
    PATTERN.new(source: source)

    Then
    error = raises(PATTERN::InvalidFilePatternError)
    error.message.include?(source.inspect)

    Where
    source
    ""
    "   "
    "!"
    "/"
    "!/"
  end

  test "patterns are values over their source" do
    Expect
    PATTERN.new(source: "bin") == PATTERN.new(source: "bin")
    PATTERN.new(source: "bin").hash == PATTERN.new(source: "bin").hash
    PATTERN.new(source: "bin") != PATTERN.new(source: "bin/")
    PATTERN.new(source: "bin").source == "bin"
  end
end
