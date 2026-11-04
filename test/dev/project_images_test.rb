# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/environment_image"
require "dev/environment_ref"
require "dev/placement"
require "dev/project_images"
require "pathname"
require "tmpdir"

# ProjectImages over a real temp checkout: deps.lock written by Lockfile.
transform!(RSpock::AST::Transformation)
class Dev::ProjectImagesTest < Minitest::Test
  include SorbetHelper

  # --- pinned / named -----------------------------------------------------

  test "pinned is the lock's image pins, in lock order, as images" do
    Given
    root = checkout(pins: [brew_pin, image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    images = Dev::ProjectImages.new(root:)

    When
    pinned = images.pinned

    Then
    pinned.map(&:class).uniq == [Dev::EnvironmentImage]
    pinned.map(&:name) == ["snappy-linux", "snappy-server"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "pinned is empty for a project pinning no image" do
    Given
    root = checkout(pins: [brew_pin])
    images = Dev::ProjectImages.new(root:)

    Expect
    images.pinned == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "named finds an image by its block name, or lists what the lock pins" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    images = Dev::ProjectImages.new(root:)

    When
    error = assert_raises(Dev::ProjectImages::UnknownImageError) { images.named("snappy-srv") }

    Then
    images.named("snappy-server").name == "snappy-server"
    error.message.include?("snappy-srv")
    error.message.include?("snappy-linux, snappy-server")

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- bind(ref): the table ---------------------------------------------

  test "bind answers a reference's placement from the lock: #{why}" do
    Given
    root = checkout(pins: [brew_pin] + pinned.map { |pin_name| image_pin(name: pin_name) })

    When
    placement = Dev::ProjectImages.new(root:).bind(ref, subject: "x")

    Then
    placement.name == expected
    placement.is_a?(expected == "host" ? Dev::Placement::Host : Dev::Placement::Image)

    Cleanup
    FileUtils.rm_rf(root)

    Where
    why                                     | ref                                               | pinned       | expected
    "host, whatever the lock"               | Dev::EnvironmentRef::Host.new                     | ["a", "b"]   | "host"
    "a name the lock pins"                  | Dev::EnvironmentRef::Image.new(name: "b")         | ["a", "b"]   | "b"
    "absent, no pin: ai-flow, plans, dev"   | nil                                               | []           | "host"
    "absent, one pin: cellbound-3d"         | nil                                               | ["a"]        | "a"
  end

  test "bind of an image reference carries the lock's image, resolved" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])
    images = Dev::ProjectImages.new(root:)

    When
    placement = images.bind(Dev::EnvironmentRef::Image.new(name: "snappy-server"), subject: "test-server")

    Then
    placement.image.equal?(images.named("snappy-server"))

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bind of the host never reads the lock: a lock another dev locked still places a host command" do
    Given "a pin another dev locked"
    root = checkout(pins: [image_pin])
    lock = Dev::Deps::Lockfile.new(dir: root)
    lock.lock(lock.read.map { |pin| pin.with(metadata: pin.metadata.merge(Dev::EnvironmentImage::DIGEST_KEY => "f" * 64)) })

    Expect
    Dev::ProjectImages.new(root:).bind(Dev::EnvironmentRef::Host.new, subject: "editor") == Dev::Placement::Host.new

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bind refuses a name the lock does not pin, naming the subject and listing what it does" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])

    When
    Dev::ProjectImages.new(root:).bind(Dev::EnvironmentRef::Image.new(name: "snappy-srv"), subject: "build")

    Then
    error = raises(Dev::ProjectImages::UnknownImageError)
    error.message.include?("`build` runs in `snappy-srv`, which the lock does not pin")
    error.message.include?("snappy-linux, snappy-server")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "bind with no reference and several pins is ambiguous: dev never guesses; both names and the key to add" do
    Given
    root = checkout(pins: [image_pin(name: "snappy-linux"), image_pin(name: "snappy-server")])

    When
    Dev::ProjectImages.new(root:).bind(nil, subject: "build")

    Then
    error = raises(Dev::ProjectImages::AmbiguousEnvironmentImageError)
    error.message.include?("`build`")
    error.message.include?("snappy-linux, snappy-server")
    error.message.include?("environment: <name>")

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- containerized? -----------------------------------------------------

  test "containerized? is whether any command could run in a container: the lock pins an image" do
    Given
    pinned = checkout(pins: [image_pin])
    plain = checkout(pins: [brew_pin])

    Expect
    Dev::ProjectImages.new(root: pinned).containerized?
    !Dev::ProjectImages.new(root: plain).containerized?

    Cleanup
    [pinned, plain].each { |dir| FileUtils.rm_rf(dir) }
  end

  test "containerized? decides membership without judging the project: a stale pin still gets its container verbs" do
    Given "a pin another dev locked"
    stale = checkout(pins: [image_pin])
    lock = Dev::Deps::Lockfile.new(dir: stale)
    lock.lock(lock.read.map { |pin| pin.with(metadata: pin.metadata.merge(Dev::EnvironmentImage::DIGEST_KEY => "f" * 64)) })
    stale_images = Dev::ProjectImages.new(root: stale)

    When "the verbs materialise the images"
    stale_error = assert_raises(Dev::EnvironmentImage::StaleDigestError) { stale_images.pinned }

    Then "membership answered; the verbs themselves raise, with the fix in the message"
    stale_images.containerized?
    stale_error.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(stale)
  end

  test "containerized? over a retired build-deps.lock is false: dev deps update must still be reachable" do
    Given "a checkout still carrying build-deps.lock"
    root = checkout(pins: [brew_pin])
    (root / "build-deps.lock").write("")

    When
    images = Dev::ProjectImages.new(root:)
    error = assert_raises(Dev::Deps::Lockfile::RetiredBuildLockError) { images.pinned }

    Then "no membership; the pins themselves still refuse"
    !images.containerized?
    error.message.include?("dev deps update")

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def checkout(pins:)
    root = Pathname(Dir.mktmpdir("project-images"))
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp(pins))
    root
  end

  def image_pin(name: "snappy-linux", platform: "linux/amd64")
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: {
        "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => platform, "platforms" => [platform],
        "registry" => "ghcr.io/d3mlabs", "apt" => ["dos2unix"],
      },
    )
  end

  def brew_pin
    Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "3.31", hash: "SHA256=0", metadata: {})
  end
end
