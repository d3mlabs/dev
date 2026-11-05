# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::TrackTest < Minitest::Test
  test "the two tracks parse from their words and know which one a release ships to" do
    Expect
    Dev::Lifecycle::Track.parse("testing") == Dev::Lifecycle::Track::Testing
    Dev::Lifecycle::Track.parse("live") == Dev::Lifecycle::Track::Live
    Dev::Lifecycle::Track::Testing.live? == false
    Dev::Lifecycle::Track::Live.live? == true
    Dev::Lifecycle::Track::Testing.to_s == "testing"
  end

  test "a word outside the set is refused with the set listed" do
    When
    Dev::Lifecycle::Track.parse("beta")

    Then
    error = raises Dev::Lifecycle::UnknownTrackError
    error.message == 'unknown track "beta" (expected testing, live)'
  end
end
