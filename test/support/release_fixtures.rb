# typed: false
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "dev/lifecycle"
require "support/fake_gh"
require "support/lifecycle_fixtures"

# A cut release as the forge would hold it (dev#424), for the tests of
# what reads one back (dev#425): the archives' bytes, the `release.json`
# that digests them, and a FakeGh serving both. Pure builders over the
# LifecycleFixtures targets; nothing is shared between calls.
module ReleaseFixtures
  include LifecycleFixtures

  RELEASE_SHA = "3f2a1c9d8e7b4455"
  RELEASE_NOON = Time.utc(2026, 11, 6, 12, 0, 0)

  # One `release.json` entry for a build, its archive named the release
  # way and digested from the bytes.
  #
  # @param build_name [String]
  # @param bytes [String] the archive's content
  # @param version [String]
  # @param extension [String]
  # @return [Dev::Lifecycle::Manifest::Release::Archive]
  def release_entry(build_name, bytes:, version: "1.2.0", extension: "zip")
    Dev::Lifecycle::Manifest::Release::Archive.new(
      build: build(build_name),
      name: "#{build_name}-#{version}.#{extension}",
      sha256: Digest::SHA256.hexdigest(bytes),
      build_id: Dev::Lifecycle::BuildId.new("#{version}+#{RELEASE_SHA[0, 12]}"),
    )
  end

  # The release of a version carrying the given archives.
  #
  # @param archives [Hash{String => String}] build name → archive bytes
  # @param version [String]
  # @param tag [String] what `release.json` says, when not the version's tag
  # @return [Dev::Lifecycle::Manifest::Release]
  def release_manifest(archives, version: "1.2.0", tag: "v#{version}")
    Dev::Lifecycle::Manifest::Release.new(
      stamp: Dev::Lifecycle::Manifest::Stamp.now(dev_version: "0.7.2", now: RELEASE_NOON),
      tag:,
      sha: RELEASE_SHA,
      archives: archives.map { |build_name, bytes| release_entry(build_name, bytes:, version:) },
    )
  end

  # Put a release on a FakeGh: `release view` answers its page (once per
  # expected lookup) and `release download` serves its assets and
  # `release.json`.
  #
  # @param gh [FakeGh]
  # @param archives [Hash{String => String}] build name → archive bytes
  # @param version [String]
  # @param lookups [Integer] how many times the release will be looked up
  # @param manifest [Dev::Lifecycle::Manifest::Release] what `release.json` says, when not the archives'
  # @return [Dev::Lifecycle::Manifest::Release] what `release.json` says
  def release_on(gh, archives, version: "1.2.0", lookups: 1, manifest: release_manifest(archives, version:))
    tag = "v#{version}"
    lookups.times { gh.answers(["release", "view", tag], with: "https://github.com/d3mlabs/cellbound-3d/releases/tag/#{tag}\n") }
    assets = archives.to_h { |build_name, bytes| ["#{build_name}-#{version}.zip", bytes] }
    gh.serves(tag, assets.merge(Dev::Lifecycle::Manifest::Release::FILE_NAME => "#{JSON.pretty_generate(manifest.to_json_hash)}\n"))
    manifest
  end
end
