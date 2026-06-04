# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/url_repository"
require "dev/deps/cache"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::UrlRepositoryTest < Minitest::Test
  test "fetch downloads URL and computes SHA256" do
    Given "a URL identifier with a stubbed download"
    dir = Dir.mktmpdir("dev-url-repo-test-")
    repo = Dev::Deps::UrlRepository.new

    fake_tarball = File.join(dir, "boost.tar.gz")
    File.write(fake_tarball, "fake tarball content for hash test")
    expected_hash = "SHA256=#{Digest::SHA256.file(fake_tarball).hexdigest}"

    repo.stubs(:download_to_tempfile).returns(fake_tarball)

    When "fetching the dependency"
    dep = repo.fetch(
      "name" => "boost",
      "url" => "https://example.com/boost-1.90.0.tar.gz",
      "integration" => "cmake",
      "group" => "app",
    )

    Then
    dep.name == "boost"
    dep.hash == expected_hash
    dep.integration == :cmake
    dep.group == :app
    dep.metadata["url"] == "https://example.com/boost-1.90.0.tar.gz"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "fetch raises DownloadError when curl fails" do
    Given "a URL repository with a stubbed failing download"
    repo = Dev::Deps::UrlRepository.new
    failed_status = stub(success?: false)
    Open3.stubs(:capture3)
         .with("curl", "-fsSL", "-o", anything, "https://example.com/missing.tar.gz")
         .returns(["", "404 Not Found", failed_status])

    When "fetching a non-existent URL"
    repo.fetch(
      "name" => "missing",
      "url" => "https://example.com/missing.tar.gz",
      "integration" => "cmake",
      "group" => "app",
    )

    Then
    raises Dev::Deps::UrlRepository::DownloadError
  end
end
