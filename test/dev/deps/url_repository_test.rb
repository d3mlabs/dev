# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/url_repository"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::UrlRepositoryTest < Minitest::Test
  test "resolve downloads URL, computes SHA256, and stores in cache" do
    Given
    dir = Dir.mktmpdir("dev-url-repo-test-")
    cache = Dev::Deps::Cache.new(cache_dir: dir)
    repo = Dev::Deps::UrlRepository.new

    # Create a fake tarball for the stub to return
    fake_tarball = File.join(dir, "boost.tar.gz")
    File.write(fake_tarball, "fake tarball content for hash test")
    expected_hash = "SHA256=#{Digest::SHA256.file(fake_tarball).hexdigest}"

    # Stub the download — UrlRepository calls download_to_tempfile internally
    repo.stubs(:download_to_tempfile).returns(fake_tarball)

    When
    pin = repo.resolve(
      "boost",
      { "url" => "https://example.com/boost-1.90.0.tar.gz",
        "integration" => "cmake", "group" => "app" },
      cache: cache,
    )

    Then
    pin.name == "boost"
    pin.hash == expected_hash
    pin.integration == :cmake
    pin.group == :app
    pin.metadata["url"] == "https://example.com/boost-1.90.0.tar.gz"
    cache.has?(expected_hash)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "dependencies returns empty array" do
    Given
    repo = Dev::Deps::UrlRepository.new
    pin = Dev::Deps::Pin.new(name: "boost", integration: :cmake, group: :app,
                              version: nil, hash: "SHA256=abc", metadata: {})

    Expect
    repo.dependencies(pin) == []
  end
end
