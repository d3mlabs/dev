# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/actions_job_context"

transform!(RSpock::AST::Transformation)
class Dev::ActionsJobContextTest < Minitest::Test
  test "inside? reads GitHub's own marker, and only its exact word: #{env.inspect}" do
    Expect
    Dev::ActionsJobContext.inside?(env) == inside

    Where
    env                            | inside
    { "GITHUB_ACTIONS" => "true" } | true
    { "GITHUB_ACTIONS" => "1" }    | false
    { "GITHUB_ACTIONS" => "" }     | false
    { "CI" => "true" }             | false
    {}                             | false
  end
end
