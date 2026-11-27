# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pip_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PipRepositoryTest < Minitest::Test
  test "find reports every installable PyPI release with its sdist digest" do
    Given "a stubbed PyPI JSON API response with two releases"
    repo = Dev::Deps::PipRepository.new
    project = {
      "releases" => {
        "2.0.5" => [
          { "packagetype" => "bdist_wheel", "digests" => { "sha256" => "wheelsha" } },
          { "packagetype" => "sdist", "digests" => { "sha256" => "sdistsha" } },
        ],
        "2.1.0" => [
          { "packagetype" => "bdist_wheel", "digests" => { "sha256" => "onlywheel" } },
        ],
      },
    }
    response = http_response("200 OK", JSON.generate(project))

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "totalsegmentator"))

    Then "sdist digest preferred, wheel fallback"
    1 * repo.get_project("totalsegmentator") >> response
    package.versions.map(&:version).sort == ["2.0.5", "2.1.0"]
    package.version("2.0.5").digest == "SHA256=sdistsha"
    package.version("2.1.0").digest == "SHA256=onlywheel"
    package.version("2.0.5").source == "totalsegmentator==2.0.5"
    package.version("2.0.5").declarations == Dev::Deps::Declarations::ToolOwned.new
  end

  test "find leaves out the releases pip has nothing to install from: yanked and file-less (dev#349)" do
    Given "a project whose 0.20.0rc2 is yanked, whose 0.9.2 has no files, and whose 0.21.0 has one yanked wheel beside a live sdist"
    repo = Dev::Deps::PipRepository.new
    project = {
      "releases" => {
        "0.9.2" => [],
        "0.20.0rc2" => [
          { "packagetype" => "sdist", "yanked" => true, "digests" => { "sha256" => "yankedsdist" } },
          { "packagetype" => "bdist_wheel", "yanked" => true, "digests" => { "sha256" => "yankedwheel" } },
        ],
        "0.21.0" => [
          { "packagetype" => "bdist_wheel", "yanked" => true, "digests" => { "sha256" => "brokenwheel" } },
          { "packagetype" => "sdist", "yanked" => false, "digests" => { "sha256" => "livesdist" } },
        ],
        "0.26.0" => [
          { "packagetype" => "sdist", "yanked" => false, "digests" => { "sha256" => "sdist26" } },
        ],
      },
    }
    response = http_response("200 OK", JSON.generate(project))

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "scikit-image"))

    Then "the universe is what pip can install; a partly yanked release stays, digested from a live file"
    1 * repo.get_project("scikit-image") >> response
    package.versions.map(&:version).sort == ["0.21.0", "0.26.0"]
    package.version("0.21.0").digest == "SHA256=livesdist"
  end

  test "find raises ProjectNotFoundError, a PackageNotFoundError, on 404" do
    Given "a PyPI API that has no such project"
    repo = Dev::Deps::PipRepository.new
    response = http_response("404 Not Found", "Not Found")

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "no-such-project"))

    Then
    1 * repo.get_project("no-such-project") >> response
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises ApiError on other HTTP failures" do
    Given "a PyPI API returning a 500"
    repo = Dev::Deps::PipRepository.new
    response = http_response("500 Internal Server Error", "Server Error")

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "flaky"))

    Then
    1 * repo.get_project("flaky") >> response
    e = raises Dev::Deps::PipRepository::ApiError
    e.message == "PyPI API returned 500 for flaky: Server Error"
  end

  test "get_project asks PyPI's JSON API for the project" do
    Given "a repository and the response PyPI will answer with"
    repo = Dev::Deps::PipRepository.new
    response = http_response("200 OK", "{}")

    When "fetching the project"
    fetched = repo.send(:get_project, "requests")

    Then "the response comes back from the project URL"
    1 * Net::HTTP.get_response(URI("https://pypi.org/pypi/requests/json")) >> response
    fetched.equal?(response)
  end
end
