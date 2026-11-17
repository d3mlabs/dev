# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/positional"

transform!(RSpock::AST::Transformation)
class Dev::Cli::PositionalTest < Minitest::Test
  test "a positional is required and single unless declared otherwise, and carries its description" do
    Expect
    !Dev::Cli::Positional.new("key", desc: "the setting's name").optional?
    !Dev::Cli::Positional.new("key", desc: "the setting's name").repeated?
    Dev::Cli::Positional.new("key", desc: "the setting's name").name == "key"
    Dev::Cli::Positional.new("key", desc: "the setting's name").desc == "the setting's name"
    Dev::Cli::Positional.new("declaration", desc: "d", optional: true, repeated: true).optional?
    Dev::Cli::Positional.new("declaration", desc: "d", optional: true, repeated: true).repeated?
  end

  test "the placeholder is the bracketed name; the usage form adds the optional and repeat markers: #{usage}" do
    Given
    positional = Dev::Cli::Positional.new("declaration", desc: "d", optional: optional, repeated: repeated)

    Expect "the Arguments block labels by the bare placeholder, the usage line by the marked one"
    positional.placeholder == "<declaration>"
    positional.usage == usage

    Where
    optional | repeated | usage
    false    | false    | "<declaration>"
    true     | false    | "[<declaration>]"
    false    | true     | "<declaration>…"
    true     | true     | "[<declaration>…]"
  end

  test "#{name.inspect} is #{expected ? "accepted" : "refused"} as a positional name" do
    When "declaring it"
    error = begin
      Dev::Cli::Positional.new(name, desc: "d")
      nil
    rescue Dev::Cli::Positional::MalformedNameError => e
      e
    end

    Then "a name is a bare lowercase word — the brackets are the rendering's; anything else is a declaration bug"
    error.nil? == expected

    Where
    name            | expected
    "key"           | true
    "n"             | true
    "owner-repo"    | true
    "build2"        | true
    "<key>"         | false
    "KEY"           | false
    "two words"     | false
    "[key]"         | false
    ""              | false
  end
end
