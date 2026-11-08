# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "digest"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::PartListTest < Minitest::Test
  def setup
    @dir = Pathname(Dir.mktmpdir("part-list-"))
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def part(name, bytes)
    (@dir / name).binwrite(bytes)
    @dir / name
  end

  test "of hashes each part in order; write renders the sha256sum shape, which read gives back" do
    Given
    files = [part("game.tar.zst.aa", "first half"), part("game.tar.zst.ab", "second half")]
    list = Dev::Lifecycle::PartList.of(files)

    When
    list.write(@dir / "game.MANIFEST")

    Then
    list.parts.map(&:name) == ["game.tar.zst.aa", "game.tar.zst.ab"]
    list.parts.first.sha256 == Digest::SHA256.hexdigest("first half")
    (@dir / "game.MANIFEST").read == "#{Digest::SHA256.hexdigest("first half")}  game.tar.zst.aa\n#{Digest::SHA256.hexdigest("second half")}  game.tar.zst.ab\n"
    Dev::Lifecycle::PartList.read(@dir / "game.MANIFEST") == list
  end

  test "renamed keeps each digest under the name the block gives" do
    Given
    list = Dev::Lifecycle::PartList.new(parts: [Dev::Lifecycle::PartList::Part.new(sha256: "ab" * 32, name: "game.tar.zst.aa")])

    When
    renamed = list.renamed { |name| name.sub("game", "game-1.2.0") }

    Then
    renamed.parts == [Dev::Lifecycle::PartList::Part.new(sha256: "ab" * 32, name: "game-1.2.0.tar.zst.aa")]
    list.parts.first.name == "game.tar.zst.aa"
  end

  test "a line that is not `<sha256>  <part>` is refused, naming the file and the line" do
    Given
    manifest = part("game.MANIFEST", "#{"ab" * 32}  game.tar.zst.aa\njust-a-word\n")

    When
    Dev::Lifecycle::PartList.read(manifest)

    Then
    error = raises(Dev::Lifecycle::PartList::MalformedPartListError)
    error.message == "#{manifest}: 'just-a-word' is not `<sha256>  <part>`"
  end

  test "an empty MANIFEST lists no part" do
    Expect
    Dev::Lifecycle::PartList.read(part("empty.MANIFEST", "")).parts == []
  end
end
