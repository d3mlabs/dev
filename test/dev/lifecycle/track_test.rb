# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::TrackTest < Minitest::Test
  test "the track set is closed — testing from the store, live from a release — and spelled one way: #{id}" do
    Expect
    Dev::Lifecycle::Track.deserialize(id) == track
    Dev::Lifecycle::Track.parse(id) == track
    track.to_s == id
    track.serialize == id

    Where
    id        | track
    "testing" | Dev::Lifecycle::Track::Testing
    "live"    | Dev::Lifecycle::Track::Live
  end

  test "there are exactly the two tracks, and only one is the track a release ships to" do
    Expect
    Dev::Lifecycle::Track.values == [Dev::Lifecycle::Track::Testing, Dev::Lifecycle::Track::Live]
    Dev::Lifecycle::Track::Testing.live? == false
    Dev::Lifecycle::Track::Live.live? == true
  end

  test "a word outside the set is refused with the set listed" do
    When
    Dev::Lifecycle::Track.parse("beta")

    Then
    error = raises Dev::Lifecycle::UnknownTrackError
    error.message == 'unknown track "beta" (expected testing, live)'
  end
end
