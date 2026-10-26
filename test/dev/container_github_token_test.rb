# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_github_token"

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
end
