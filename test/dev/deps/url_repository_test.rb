# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/url_repository"
require "tmpdir"
require "digest"

transform!(RSpock::AST::Transformation)
class Dev::Deps::UrlRepositoryTest < Minitest::Test
  test "find downloads the URL and reports it as a digested, unversioned singleton" do
    Given "a URL, and a curl that writes nothing into the tempfile it is handed"
    repo = Dev::Deps::UrlRepository.new
    url = "https://example.com/boost-1.90.0.tar.gz"
    expected_hash = "SHA256=#{Digest::SHA256.hexdigest("")}"

    When "finding"
    package = repo.find(Dev::Deps::PackageId.new(integration: :url, name: "boost", source: url))

    Then "TOFU integrity: the downloaded bytes' SHA256 is the digest; no version exists"
    1 * Open3.capture3("curl", "-fsSL", "-o", anything, url) >> ["", "", exit_status(0)]
    package.versions.size == 1
    version = package.versions.first
    version.version == ""
    version.digest == expected_hash
    version.source == url
    version.artifacts["default"].uri == url
    version.metadata == { "url" => url }
    version.declarations == Dev::Deps::Declarations::Resolved.new([])
  end

  test "find raises DownloadError when curl fails" do
    Given "a URL repository whose curl fails"
    repo = Dev::Deps::UrlRepository.new

    When "finding a non-existent URL"
    repo.find(
      Dev::Deps::PackageId.new(
        integration: :url, name: "missing", source: "https://example.com/missing.tar.gz",
      ),
    )

    Then
    _ * Open3.capture3("curl", "-fsSL", "-o", anything, "https://example.com/missing.tar.gz") >>
      ["", "404 Not Found", exit_status(1)]
    raises Dev::Deps::UrlRepository::DownloadError
  end

  test "download_to_tempfile returns the temp path when curl succeeds" do
    Given "a successful curl"
    repo = Dev::Deps::UrlRepository.new

    When "downloading"
    path = repo.send(:download_to_tempfile, "https://example.com/ok.tar.gz", "ok")

    Then "the tempfile path comes back for hashing"
    _ * Open3.capture3("curl", "-fsSL", "-o", anything, "https://example.com/ok.tar.gz") >> ["", "", exit_status(0)]
    File.exist?(path) == true
  end
end
