# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/pip_repository"

transform!(RSpock::AST::Transformation)
class Dev::Deps::PipRepositoryTest < Minitest::Test
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
