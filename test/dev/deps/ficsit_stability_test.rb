# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/ficsit_stability"
require "dev/lifecycle/track"

transform!(RSpock::AST::Transformation)
class Dev::Deps::FicsitStabilityTest < Minitest::Test
  test "the #{track} track ships as SMR's #{stability} stability" do
    Expect
    Dev::Deps::FicsitStability.for_track(track) == expected
    Dev::Deps::FicsitStability.for_track(track).to_s == stability

    Where
    track                          | expected                            | stability
    Dev::Lifecycle::Track::Testing | Dev::Deps::FicsitStability::Beta    | "beta"
    Dev::Lifecycle::Track::Live    | Dev::Deps::FicsitStability::Release | "release"
  end

  test "the three stabilities are SMR's VersionStabilities, and alpha is never a track's" do
    Expect
    Dev::Deps::FicsitStability.values.map(&:serialize) == ["alpha", "beta", "release"]
    Dev::Lifecycle::Track.values.map { |track| Dev::Deps::FicsitStability.for_track(track) }.none?(Dev::Deps::FicsitStability::Alpha)
  end
end
