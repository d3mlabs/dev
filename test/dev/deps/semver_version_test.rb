# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/semver_version"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SemverVersionTest < Minitest::Test
  SemverVersion = Dev::Deps::SemverVersion

  test "#{string.inspect} parses into its parts and prints as written" do
    When "parsing"
    version = SemverVersion.parse(string)

    Then
    [version.segments, version.prerelease, version.build] == [segments, prerelease, build]
    version.to_s == string

    Where
    string                 | segments  | prerelease      | build
    "1"                    | [1]       | []              | nil
    "1.2"                  | [1, 2]    | []              | nil
    "1.2.3"                | [1, 2, 3] | []              | nil
    "1.2.3-rc.1"           | [1, 2, 3] | ["rc", "1"]     | nil
    "1.2.3-beta.2+build.5" | [1, 2, 3] | ["beta", "2"]   | "build.5"
    "1.2.3+sha.deadbeef"   | [1, 2, 3] | []              | "sha.deadbeef"
    "1.2-alpha"            | [1, 2]    | ["alpha"]       | nil
    "0.0.0-0"              | [0, 0, 0] | ["0"]           | nil
  end

  test "#{string.inspect} is not a semver version" do
    When
    SemverVersion.parse(string)

    Then
    raises SemverVersion::InvalidVersionError

    Where
    string
    ""
    "v1.2.3"
    "1.2.3.4"
    "3.11.4_1"
    "1.0r3"
    "2.0.x"
    "1.2.3-"
    "latest"
  end

  test "#{left} <=> #{right} is #{expected} under semver precedence" do
    Expect
    (SemverVersion.parse(left) <=> SemverVersion.parse(right)) == expected

    Where
    left           | right          | expected
    "1.0.0"        | "1.0.0"        | 0
    "1.0"          | "1.0.0"        | 0
    "1"            | "1.0.0"        | 0
    "1.0.0+a"      | "1.0.0+b"      | 0
    "1.0.1"        | "1.0.0"        | 1
    "1.10.0"       | "1.9.0"        | 1
    "2.0.0"        | "1.99.99"      | 1
    "1.0.0-rc.1"   | "1.0.0"        | -1
    "1.0.0"        | "1.0.0-rc.1"   | 1
    "1.0.0-alpha"  | "1.0.0-beta"   | -1
    "1.0.0-rc.2"   | "1.0.0-rc.10"  | -1
    "1.0.0-0"      | "1.0.0-rc.1"   | -1
    "1.0.0-rc.1"   | "1.0.0-rc"     | 1
    "1.0.0-alpha"  | "1.0.0-1"      | 1
    "1.0.1-rc.1"   | "1.0.0"        | 1
  end

  test "comparison with anything else is nil" do
    Expect
    (SemverVersion.parse("1.0.0") <=> "1.0.0").nil?
    SemverVersion.parse("1.0.0") != "1.0.0"
  end

  test "release and padded fill the unwritten segments; release drops the prerelease" do
    Expect
    SemverVersion.parse("1.2").release.to_s == "1.2.0"
    SemverVersion.parse("2.0.0-rc.1").release.to_s == "2.0.0"
    SemverVersion.parse("1.2-beta.1+build").padded.to_s == "1.2.0-beta.1"
    SemverVersion.parse("1.2.3").padded.to_s == "1.2.3"
    SemverVersion.parse("2.0.0-rc.1").prerelease?
    !SemverVersion.parse("2.0.0").prerelease?
  end

  test "#{string} bumped at #{index} is #{expected}" do
    Expect
    SemverVersion.parse(string).bump(index).to_s == expected

    Where
    string  | index | expected
    "1.2.3" | 0     | "2.0.0"
    "1.2.3" | 1     | "1.3.0"
    "1.2.3" | 2     | "1.2.4"
    "0.2"   | 1     | "0.3.0"
    "1"     | 0     | "2.0.0"
  end

  test "bumping an unwritten segment is refused" do
    When
    SemverVersion.parse("1.2").bump(2)

    Then
    raises IndexError
  end
end
