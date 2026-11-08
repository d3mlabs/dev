# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_github_token"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::ContainerGithubTokenTest < Minitest::Test
  test "the host's token rides along as GH_TOKEN" do
    Expect
    Dev::ContainerGithubToken.new(source: -> { "gho_secret" }).merge_into({ "A" => "1" }) ==
      { "A" => "1", "GH_TOKEN" => "gho_secret" }
  end

  test "a GH_TOKEN the run_env names wins over the host's" do
    Expect
    Dev::ContainerGithubToken.new(source: -> { "gho_host" }).merge_into({ "GH_TOKEN" => "gho_mine" }) ==
      { "GH_TOKEN" => "gho_mine" }
  end

  test "no token when the host holds none" do
    Expect
    Dev::ContainerGithubToken.new(source: -> { token }).merge_into({ "A" => "1" }) == expected

    Where
    token | expected
    nil   | { "A" => "1" }
    ""    | { "A" => "1" }
  end

  test "HOST asks gh on the PATH and answers #{expected.inspect} when gh #{behaviour}" do
    Given "a PATH holding only a gh that #{behaviour}"
    dir = Dir.mktmpdir("gh-on-path-")
    if script
      File.write(File.join(dir, "gh"), "#!/bin/sh\n#{script}\n")
      File.chmod(0o755, File.join(dir, "gh"))
    end
    original_path = ENV["PATH"]
    ENV["PATH"] = dir

    When "asking for the host's token"
    token = Dev::ContainerGithubToken::HOST.call

    Then
    token == expected

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)

    Where
    behaviour              | script                                  | expected
    "prints a token"       | 'echo "gho_fromhost"'                   | "gho_fromhost"
    "is not logged in"     | "echo 'not logged in' >&2; exit 1"      | nil
    "is not installed"     | nil                                     | nil
  end
end
