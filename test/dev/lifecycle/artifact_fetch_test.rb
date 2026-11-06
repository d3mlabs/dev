# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::ArtifactFetchTest < Minitest::Test
  test "a fetch names the workflow artifact and where it lands, and compares by both" do
    Given
    fetch = Dev::Lifecycle::ArtifactFetch.new(name: "rspock", into: Pathname("/data/artifacts/rspock"))
    same = Dev::Lifecycle::ArtifactFetch.new(name: "rspock", into: Pathname("/data/artifacts/rspock"))

    Expect
    fetch.name == "rspock"
    fetch.into == Pathname("/data/artifacts/rspock")
    fetch == same
    fetch.eql?(same)
    fetch.hash == same.hash
    fetch != Dev::Lifecycle::ArtifactFetch.new(name: "rspock", into: Pathname("/elsewhere"))
    fetch != Dev::Lifecycle::ArtifactFetch.new(name: "other", into: Pathname("/data/artifacts/rspock"))
    fetch != "rspock"
  end
end
