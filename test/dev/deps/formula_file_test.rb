# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/formula_file"
require "fileutils"
require "pathname"
require "tmpdir"
require "uri"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FormulaFileTest < Minitest::Test
  SPEC = Dev::Deps::FormulaFile::StableSpec

  # dev-core.rb's shape: a stable spec, then vendored resources with their
  # own url/sha256 pairs, and an em dash in a comment.
  FORMULA = <<~RUBY
    # Global dev CLI — the org-blank tool.
    class DevCore < Formula
      desc "Find repo with dev.yml and run declared commands"
      homepage "https://github.com/d3mlabs/dev"
      url "https://github.com/d3mlabs/dev/archive/refs/tags/v0.7.13.tar.gz"
      sha256 "6e1217f48a323da2e4dd1fac4c7e7d761aa60b39b0e4f2afb784459d5fc1f493"

      depends_on "gh"

      resource "cli-ui" do
        url "https://rubygems.org/downloads/cli-ui-2.7.0.gem"
        sha256 "e36147f2e8088796b996f0560f577bd1599f2b6aa3c374fe09fff59af5589c35"
      end
    end
  RUBY

  ASSET = "https://github.com/d3mlabs/dev/releases/download/v0.8.0/dev-core-0.8.0.zip"
  SHA = "ab" * 32

  def setup
    @dir = Pathname(Dir.mktmpdir("formula-file-"))
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def formula(contents = FORMULA, name: "dev-core")
    path = @dir / "#{name}.rb"
    path.write(contents, encoding: "UTF-8")
    Dev::Deps::FormulaFile.new(path:)
  end

  test "dependencies are the formula's depends_on names as brew resolves them — the last segment of a tap-qualified name — in file order, blocks included (dev#531)" do
    Given
    file = formula(<<~RUBY, name: "dev")
      class Dev < Formula
        url "https://example.com/dev-0.8.0.zip"
        sha256 "#{SHA}"

        depends_on "d3mlabs/d3mlabs/dev-core"
        depends_on "gh" => :build
        depends_on "ruby"

        on_macos do
          depends_on "colima"
        end

        resource "cli-ui" do
          url "https://rubygems.org/downloads/cli-ui-2.7.0.gem"
        end
      end
    RUBY

    Expect
    file.dependencies == %w[dev-core gh ruby colima]
  end

  test "a formula with no depends_on has no dependencies" do
    Expect
    formula(FORMULA.sub("  depends_on \"gh\"\n", "")).dependencies == []
  end

  test "the stable spec is the first url and the sha256 that follows it; the name is the file's" do
    Given
    file = formula

    Expect
    file.name == "dev-core"
    file.stable_spec == SPEC.new(
      url: URI.parse("https://github.com/d3mlabs/dev/archive/refs/tags/v0.7.13.tar.gz"),
      sha256: "6e1217f48a323da2e4dd1fac4c7e7d761aa60b39b0e4f2afb784459d5fc1f493",
    )
  end

  test "write_stable_spec rewrites those two lines only: a resource's sha256, the indentation, the comment's em dash and the ending stay" do
    Given
    file = formula

    When
    file.write_stable_spec(SPEC.new(url: URI.parse(ASSET), sha256: SHA))

    Then "the file is the same but for the two lines, and reads back as the new spec"
    file.path.read(encoding: "UTF-8") == FORMULA
      .sub("https://github.com/d3mlabs/dev/archive/refs/tags/v0.7.13.tar.gz", ASSET)
      .sub("6e1217f48a323da2e4dd1fac4c7e7d761aa60b39b0e4f2afb784459d5fc1f493", SHA)
    file.stable_spec == SPEC.new(url: URI.parse(ASSET), sha256: SHA)
  end

  test "a formula whose stable spec is a source tarball moves to a release asset by the same rewrite — the url's shape is not anchored" do
    Given "a formula already pointing at a release asset of another version"
    file = formula(FORMULA.sub("https://github.com/d3mlabs/dev/archive/refs/tags/v0.7.13.tar.gz", ASSET.sub("0.8.0", "0.7.14")))

    When
    file.write_stable_spec(SPEC.new(url: URI.parse(ASSET), sha256: SHA))

    Then
    file.stable_spec.url == URI.parse(ASSET)
  end

  test "a file with #{what} has no stable spec" do
    Given
    file = formula(contents)

    When
    file.stable_spec

    Then
    error = raises(Dev::Deps::FormulaFile::NoStableSpecError)
    error.message.include?(file.path.to_s)

    Where
    what                                  | contents
    "no url line"                         | "class Dev < Formula\n  desc \"x\"\nend\n"
    "a url and no sha256 after it"        | "class Dev < Formula\n  url \"https://x/a.zip\"\n  depends_on \"gh\"\nend\n"
    "two urls before the first sha256"    | "class Dev < Formula\n  url \"https://x/a.zip\"\n  mirror \"y\"\n  url \"https://x/b.zip\"\n  sha256 \"#{"ab" * 32}\"\nend\n"
  end

  test "two specs are equal when url and sha256 are, and print as one line" do
    Given
    a = SPEC.new(url: URI.parse(ASSET), sha256: SHA)
    b = SPEC.new(url: URI.parse(ASSET), sha256: SHA)
    c = SPEC.new(url: URI.parse(ASSET), sha256: "cd" * 32)

    Expect
    a == b
    a.eql?(b)
    a.hash == b.hash
    a != c
    a.to_s == "#{ASSET} (#{SHA})"
  end
end
