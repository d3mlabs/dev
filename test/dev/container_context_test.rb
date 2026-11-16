# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_context"

transform!(RSpock::AST::Transformation)
class Dev::ContainerContextTest < Minitest::Test
  include SorbetHelper

  test "inside? reads the marker the container service sets on the container" do
    Expect "only the exact marker value counts"
    Dev::ContainerContext.inside?(env) == expected

    Where
    env                                | expected
    {}                                 | false
    { "DEV_INSIDE_CONTAINER" => "1" }  | true
    { "DEV_INSIDE_CONTAINER" => "0" }  | false
    { "DEV_INSIDE_CONTAINER" => "" }   | false
    { "DEV_INSIDE_CONTAINER" => "yes" } | false
  end

  test "MARKER_ENV is what the container service injects, and inside? recognizes it" do
    Expect "the two halves of the contract agree"
    Dev::ContainerContext::MARKER_ENV == { "DEV_INSIDE_CONTAINER" => "1" }
    Dev::ContainerContext.inside?(Dev::ContainerContext::MARKER_ENV)
  end

  test "side names the #{expected} side of the build container, as store keys carry it" do
    Expect
    Dev::ContainerContext.side(inside: inside) == expected

    Where
    inside | expected
    false  | "host"
    true   | "container"
  end

  test "side defaults to the process's own side" do
    Given "the marker set in ENV"
    original = ENV["DEV_INSIDE_CONTAINER"]
    ENV["DEV_INSIDE_CONTAINER"] = "1"

    Expect "the default argument reads it as the container's"
    Dev::ContainerContext.side == Dev::ContainerContext::CONTAINER_SIDE

    Cleanup
    if original.nil?
      ENV.delete("DEV_INSIDE_CONTAINER")
    else
      ENV["DEV_INSIDE_CONTAINER"] = original
    end
  end

  test "inside? defaults to the process environment" do
    Given "the marker set in ENV"
    original = ENV["DEV_INSIDE_CONTAINER"]
    ENV["DEV_INSIDE_CONTAINER"] = "1"

    Expect "the default argument sees it"
    Dev::ContainerContext.inside?

    Cleanup
    if original.nil?
      ENV.delete("DEV_INSIDE_CONTAINER")
    else
      ENV["DEV_INSIDE_CONTAINER"] = original
    end
  end
end
