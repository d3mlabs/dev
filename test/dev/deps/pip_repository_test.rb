# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pip_repository"

# PipRepository is the adapter over PyPI's JSON API, so the GET it makes is
# its contract and the answer is a real response: how it reads the status
# class and the body is the behaviour under test.
transform!(RSpock::AST::Transformation)
class Dev::Deps::PipRepositoryTest < Minitest::Test
  PYPI = Dev::Deps::PipRepository::PYPI_HOST

  test "find reports every installable PyPI release with its sdist digest" do
    Given "a PyPI JSON API document with two releases"
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

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "totalsegmentator"))

    Then "the project's document is asked for once; sdist digest preferred, wheel fallback"
    1 * Net::HTTP.get_response(URI("#{PYPI}/pypi/totalsegmentator/json")) >> http_response("200", body: JSON.generate(project))
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

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "scikit-image"))

    Then "the universe is what pip can install; a partly yanked release stays, digested from a live file"
    1 * Net::HTTP.get_response(URI("#{PYPI}/pypi/scikit-image/json")) >> http_response("200", body: JSON.generate(project))
    package.versions.map(&:version).sort == ["0.21.0", "0.26.0"]
    package.version("0.21.0").digest == "SHA256=livesdist"
  end

  test "find raises ProjectNotFoundError, a PackageNotFoundError, on 404" do
    Given "a PyPI API that has no such project"
    repo = Dev::Deps::PipRepository.new

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "no-such-project"))

    Then
    1 * Net::HTTP.get_response(URI("#{PYPI}/pypi/no-such-project/json")) >> http_response("404", body: "Not Found")
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises ApiError on other HTTP failures" do
    Given "a PyPI API returning a 500"
    repo = Dev::Deps::PipRepository.new

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "flaky"))

    Then
    1 * Net::HTTP.get_response(URI("#{PYPI}/pypi/flaky/json")) >> http_response("500", body: "Server Error")
    e = raises Dev::Deps::PipRepository::ApiError
    e.message == "PyPI API returned 500 for flaky: Server Error"
  end
end
