# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/flag"

transform!(RSpock::AST::Transformation)
class Dev::Cli::FlagTest < Minitest::Test
  test "a flag is a switch unless declared value-taking" do
    Expect
    !Dev::Cli::Flag.new("--org").takes_value?
    Dev::Cli::Flag.new("--keep", takes_value: true).takes_value?
    Dev::Cli::Flag.new("--keep", takes_value: true).name == "--keep"
  end

  test "a flag carries a one-line description for the usage listing, empty unless given" do
    Expect
    Dev::Cli::Flag.new("--org").desc == ""
    Dev::Cli::Flag.new("--org", desc: "enroll at the org scope").desc == "enroll at the org scope"
  end

  test "#{name.inspect} is #{expected ? "accepted" : "refused"} as a flag name" do
    When "declaring it"
    error = begin
      Dev::Cli::Flag.new(name)
      nil
    rescue Dev::Cli::Flag::MalformedNameError => e
      e
    end

    Then "a name is dashes plus a word; anything else is a declaration bug"
    error.nil? == expected

    Where
    name           | expected
    "--org"        | true
    "-v"           | true
    "--tool-caches" | true
    "org"          | false
    "--"           | false
    "-"            | false
    "--keep=3"     | false
    ""             | false
  end
end
