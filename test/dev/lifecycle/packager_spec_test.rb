# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::PackagerSpecTest < Minitest::Test
  SPEC = Dev::Lifecycle::PackagerSpec
  FORM = Dev::Lifecycle::Archive::Form

  test "each declaration renders as dev.yml spells it and is a value: #{rendered}" do
    Expect
    spec.to_s == rendered
    spec == same
    spec.hash == same.hash
    spec != SPEC::Script.new(command: "other")

    Where
    spec                                                                           | same                                                                           | rendered
    SPEC::Archive.new                                                              | SPEC::Archive.new(form: FORM::Zip.new)                                         | "archive"
    SPEC::Archive.new(form: FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))) | SPEC::Archive.new(form: FORM::Tar.new(split: Dev::Lifecycle::ByteSize.parse("2GiB"))) | "archive (tar, split 2GiB)"
    SPEC::AsIs.new                                                                 | SPEC::AsIs.new                                                                 | "as-is"
    SPEC::None.new                                                                 | SPEC::None.new                                                                 | "none"
    SPEC::Script.new(command: "./bin/package")                                     | SPEC::Script.new(command: "./bin/package")                                     | "./bin/package"
  end

  test "the built-in names are the three a packager: line may carry" do
    Expect
    SPEC::BUILTIN_NAMES == ["archive", "as-is", "none"]
  end

  test "a builder declaration renders as its line and is a value" do
    Expect
    Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build").to_s == "./bin/build"
    Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build") == Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build")
    Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build").hash == Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build").hash
    Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/build") != Dev::Lifecycle::BuilderSpec::Script.new(command: "./bin/other")
  end
end
