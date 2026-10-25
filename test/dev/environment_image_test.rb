# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_image"
require "dev/deps/dependency"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::EnvironmentImageTest < Minitest::Test
  FLOOR_DIGEST = "a" * 64

  test "the generated Dockerfile is the floor by digest, the apt layer, dev's contract, and the marker from a build arg" do
    Given "a locked image pin"
    image = Dev::EnvironmentImage.from_pin(pin(apt: ["winbind", "dos2unix"]))

    Expect "exactly this text — the digest is computed over it, so it is the contract"
    image.dockerfile == expected_dockerfile
  end

  test "an image with no apt lines is the floor plus dev's contract: no apt layer at all" do
    Expect
    !Dev::EnvironmentImage.from_pin(pin(apt: [])).dockerfile.include?("apt-get")
  end

  test "digest is the SHA-256 of the Dockerfile text; tag, marker and build arg all carry it" do
    Given
    image = Dev::EnvironmentImage.from_pin(pin)

    Expect "one spelling of the identity everywhere"
    image.digest == Digest::SHA256.hexdigest(image.dockerfile)
    image.digest.match?(/\A[0-9a-f]{64}\z/)
    image.tag == image.digest
    image.ref == "ghcr.io/d3mlabs/snappy-linux:#{image.digest}"
    image.build_args == { "DEV_ENVIRONMENT_DIGEST" => image.digest }
    image.marker == "name=snappy-linux\ndigest=#{image.digest}\n"
    image.short_digest == image.digest[0, 12]
  end

  test "the digest changes with every input: #{what}" do
    Given
    base = Dev::EnvironmentImage.from_pin(pin)

    Expect
    Dev::EnvironmentImage.from_pin(pin(**change)).digest != base.digest

    Where
    what                 | change
    "the floor's digest" | { from_digest: "b" * 64 }
    "the floor's name"   | { from: "ghcr.io/d3mlabs/other-floor" }
    "the platform"       | { platform: "linux/arm64", platforms: ["linux/amd64", "linux/arm64"] }
    "the apt set"        | { apt: ["libnss3"] }
    "the image's name"   | { name: "other" }
  end

  test "the digest ignores what is not image content: the registry it publishes to, apt order" do
    Expect
    Dev::EnvironmentImage.from_pin(pin(registry: "elsewhere.io/x")).digest == Dev::EnvironmentImage.from_pin(pin).digest
    Dev::EnvironmentImage.from_pin(pin(apt: ["b", "a"])).digest == Dev::EnvironmentImage.from_pin(pin(apt: ["a", "b"])).digest
  end

  test "platform is inferred from a single-platform floor" do
    Expect
    Dev::EnvironmentImage.from_pin(pin(platform: nil, platforms: ["linux/arm64/v8"])).platform == "linux/arm64/v8"
  end

  test "platform is required for a multi-arch floor" do
    When
    Dev::EnvironmentImage.from_pin(pin(platform: nil, platforms: ["linux/amd64", "linux/arm64"]))

    Then
    error = raises(Dev::EnvironmentImage::PlatformError)
    error.message.include?("platform")
  end

  test "a platform the floor does not publish is a PlatformError" do
    When
    Dev::EnvironmentImage.from_pin(pin(platform: "linux/arm64", platforms: ["linux/amd64"]))

    Then
    raises Dev::EnvironmentImage::PlatformError
  end

  test "dev_platform is the platform as dev's key, variant dropped" do
    Expect
    Dev::EnvironmentImage.from_pin(pin).dev_platform == "linux-x86_64"
    Dev::EnvironmentImage.from_pin(pin(platform: "linux/arm64/v8", platforms: ["linux/arm64/v8"])).dev_platform == "linux-arm64"
  end

  test "floor_ref is the floor pinned by digest — what the FROM line pulls" do
    Expect
    Dev::EnvironmentImage.from_pin(pin).floor_ref == "ghcr.io/d3mlabs/unreal-engine-build-base@sha256:#{FLOOR_DIGEST}"
  end

  test "from_pin accepts a pin whose stored digest is what this dev computes" do
    Given
    current = Dev::EnvironmentImage.from_pin(pin)

    Expect
    Dev::EnvironmentImage.from_pin(pin(digest: current.digest)).digest == current.digest
  end

  test "from_pin refuses a pin locked by another dev as stale, naming the re-lock" do
    When "the lock carries a digest this dev's template would not produce"
    Dev::EnvironmentImage.from_pin(pin(digest: "f" * 64))

    Then
    error = raises(Dev::EnvironmentImage::StaleDigestError)
    error.message.include?("dev deps update")
  end

  test "with_digest stamps the pin's metadata with the computed digest, the lock's copy to check against" do
    Given
    dep = pin
    image = Dev::EnvironmentImage.from_pin(dep)

    When
    stamped = image.with_digest(dep)

    Then
    stamped.metadata["digest"] == image.digest
    stamped.metadata.except("digest") == dep.metadata
  end

  test "stamp writes the digest onto every :image pin and leaves other pins alone" do
    Given
    other = Dev::Deps::Dependency.new(name: "rake", integration: :bundler, group: :app, version: "13", hash: nil, metadata: {})

    When
    stamped = Dev::EnvironmentImage.stamp([other, pin, pin(name: "two")])

    Then
    stamped[0].equal?(other)
    stamped[1].metadata["digest"] == Dev::EnvironmentImage.from_pin(pin).digest
    stamped[2].metadata["digest"] == Dev::EnvironmentImage.from_pin(pin(name: "two")).digest
  end

  test "stamp re-stamps a pin carrying a stale digest: the re-lock is where staleness is cured, not refused" do
    When
    stamped = Dev::EnvironmentImage.stamp([pin(digest: "f" * 64)])

    Then
    stamped[0].metadata["digest"] == Dev::EnvironmentImage.from_pin(pin).digest
  end

  private

  # Built from lines, not a heredoc: the test transformer cannot round-trip
  # an interpolated heredoc with escapes.
  def expected_dockerfile
    [
      "FROM --platform=linux/amd64 ghcr.io/d3mlabs/unreal-engine-build-base@sha256:" + FLOOR_DIGEST,
      "USER root",
      "ENV DEBIAN_FRONTEND=noninteractive",
      'RUN apt-get -y update \\',
      '    && apt-get -y install --no-install-recommends dos2unix winbind \\',
      '    && apt-get clean \\',
      '    && rm -rf /var/lib/apt/lists/*',
      'ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"',
      "ARG DEV_ENVIRONMENT_DIGEST",
      'RUN install -d /etc/dev \\',
      %q(    && printf 'name=%s\ndigest=%s\n' snappy-linux "$DEV_ENVIRONMENT_DIGEST" > /etc/dev/environment),
      "USER builder",
      "WORKDIR /project",
    ].join("\n") + "\n"
  end

  def pin(name: "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base", from_digest: FLOOR_DIGEST,
    platform: "linux/amd64", platforms: ["linux/amd64"], registry: "ghcr.io/d3mlabs", apt: ["dos2unix"], digest: nil)
    metadata = { "from" => from, "platform" => platform, "platforms" => platforms, "registry" => registry, "apt" => apt }
    metadata["digest"] = digest if digest
    Dev::Deps::Dependency.new(
      name: name, integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{from_digest}", metadata: metadata,
    )
  end
end
