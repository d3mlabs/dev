# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pip_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PipRepositoryTest < Minitest::Test
  test "find reports every PyPI release with its sdist digest" do
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
        "1.9.0" => [],
      },
    }
    response = stub(body: JSON.generate(project))
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    repo.stubs(:get_project).with("totalsegmentator").returns(response)

    When "finding the package"
    package = repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "totalsegmentator"))

    Then "sdist digest preferred, wheel fallback, nil for file-less releases"
    package.versions.map(&:version).sort == ["1.9.0", "2.0.5", "2.1.0"]
    package.version("2.0.5").digest == "SHA256=sdistsha"
    package.version("2.1.0").digest == "SHA256=onlywheel"
    package.version("1.9.0").digest.nil?
    package.version("2.0.5").dependencies == []
  end

  test "find raises ProjectNotFoundError, a PackageNotFoundError, on 404" do
    Given "a PyPI API that has no such project"
    repo = Dev::Deps::PipRepository.new
    response = stub(code: "404", body: "Not Found")
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(false)
    response.stubs(:is_a?).with(Net::HTTPNotFound).returns(true)
    repo.stubs(:get_project).with("no-such-project").returns(response)

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "no-such-project"))

    Then
    raises Dev::Deps::Repository::PackageNotFoundError
  end

  test "find raises ApiError on other HTTP failures" do
    Given "a PyPI API returning a 500"
    repo = Dev::Deps::PipRepository.new
    response = stub(code: "500", body: "Server Error")
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(false)
    response.stubs(:is_a?).with(Net::HTTPNotFound).returns(false)
    repo.stubs(:get_project).with("flaky").returns(response)

    When "finding the package"
    repo.find(Dev::Deps::PackageId.new(integration: :pip, name: "flaky"))

    Then
    raises Dev::Deps::PipRepository::ApiError
  end

  test "reads the version #{expected} from #{filename}" do
    Given "a repository"
    repo = Dev::Deps::PipRepository.new

    Expect "the version is the first digit-leading token after the name"
    repo.send(:version_from_filename, filename, "totalsegmentator") == expected

    Where
    filename                                            | expected
    "totalsegmentator-2.0.5-py3-none-any.whl"           | "2.0.5"
    "TotalSegmentator-2.0.5.tar.gz"                     | "2.0.5"
    "kimimaro-3.4.0-cp312-cp312-macosx_11_0_arm64.whl"  | "3.4.0"
    "some_pkg-1.0.zip"                                  | "1.0"
  end

  test "normalize_constraint maps #{input} to #{expected}" do
    Given "a repository"
    repo = Dev::Deps::PipRepository.new

    Expect "bare versions become == pins, operatored constraints pass through, blanks stay empty"
    repo.send(:normalize_constraint, input) == expected

    Where
    input     | expected
    "2.0.5"   | "==2.0.5"
    ">=2.0"   | ">=2.0"
    "~=2.1"   | "~=2.1"
    nil       | ""
    ""        | ""
  end
end
