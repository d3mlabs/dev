# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::PackedArchiveTest < Minitest::Test
  test "a one-file archive is its own file set" do
    Given
    packed = Dev::Lifecycle::PackedArchive.new(archive: Pathname("/store/cb-win64-dev/cb-win64-dev.zip"))

    Expect
    packed.name == "cb-win64-dev.zip"
    packed.files == [Pathname("/store/cb-win64-dev/cb-win64-dev.zip")]
    !packed.split?
    packed == Dev::Lifecycle::PackedArchive.new(archive: Pathname("/store/cb-win64-dev/cb-win64-dev.zip"))
    packed.hash == Dev::Lifecycle::PackedArchive.new(archive: Pathname("/store/cb-win64-dev/cb-win64-dev.zip")).hash
  end

  test "a split set is the MANIFEST then its parts" do
    Given
    parts = [Pathname("/store/ue/ue.tar.zst.00"), Pathname("/store/ue/ue.tar.zst.01")]
    packed = Dev::Lifecycle::PackedArchive.new(archive: Pathname("/store/ue/ue.MANIFEST"), parts:)

    Expect
    packed.name == "ue.MANIFEST"
    packed.split?
    packed.files == [Pathname("/store/ue/ue.MANIFEST"), *parts]
    packed != Dev::Lifecycle::PackedArchive.new(archive: Pathname("/store/ue/ue.MANIFEST"))
  end
end
