# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/gh_auth"

transform!(RSpock::AST::Transformation)
class Dev::GhAuthTest < Minitest::Test
  include SorbetHelper

  test "token is gh's token, stripped of its trailing newline" do
    Given
    auth = Dev::GhAuth.new

    When "gh holds a token"
    token = auth.token

    Then
    _ * Open3.capture3("gh", "auth", "token") >> ["gho_abc123\n", "", exit_status(0)]
    token == "gho_abc123"
  end

  test "token raises NotAuthenticatedError, naming gh auth login, when gh has none" do
    Given
    auth = Dev::GhAuth.new

    When "no gh login"
    auth.token

    Then
    _ * Open3.capture3("gh", "auth", "token") >> ["", "no oauth token found for github.com — run gh auth login", exit_status(1)]
    error = raises(Dev::GhAuth::NotAuthenticatedError)
    error.message.include?("gh auth login")
  end

  test "login is the authenticated user's handle, asked once" do
    Given
    auth = Dev::GhAuth.new

    When "gh answers the user query, and login is read twice"
    first = auth.login
    second = auth.login

    Then "the same answer twice without a second call"
    1 * Open3.capture3("gh", "api", "user", "--jq", ".login") >> ["jpduchesne\n", "", exit_status(0)]
    first == "jpduchesne"
    second == "jpduchesne"
  end

  test "login falls back to a placeholder when the token cannot read /user (a workflow's installation token)" do
    Given
    auth = Dev::GhAuth.new

    When "gh refuses the user query"
    login = auth.login

    Then "a registry login still has a username to send; GHCR ignores it"
    _ * Open3.capture3("gh", "api", "user", "--jq", ".login") >> ["", "HTTP 403: Resource not accessible by integration", exit_status(1)]
    login == Dev::GhAuth::ANONYMOUS_LOGIN
  end

  test "scopes are parsed off the X-OAuth-Scopes header of an authenticated response" do
    Given "a classic token's response headers"
    auth = Dev::GhAuth.new
    response = <<~HTTP
      HTTP/2.0 200 OK
      Content-Type: application/json; charset=utf-8
      X-Oauth-Scopes: gist, read:org, read:packages, repo
      X-Ratelimit-Limit: 5000

      {"resources":{}}
    HTTP

    When
    scopes = auth.scopes

    Then
    _ * Open3.capture3("gh", "api", "-i", "rate_limit") >> [response, "", exit_status(0)]
    scopes == ["gist", "read:org", "read:packages", "repo"]
  end

  test "scopes are empty when the response carries no scopes header (installation and fine-grained tokens)" do
    Given
    auth = Dev::GhAuth.new

    When "a response without the header"
    scopes = auth.scopes

    Then
    _ * Open3.capture3("gh", "api", "-i", "rate_limit") >> ["HTTP/2.0 200 OK\nContent-Type: application/json\n\n{}\n", "", exit_status(0)]
    scopes == []
    !auth.scopes_reported?
  end

  test "require_scope! passes when the token carries the scope" do
    Given
    auth = Dev::GhAuth.new

    When
    auth.require_scope!(Dev::GhAuth::READ_PACKAGES)

    Then "no refusal"
    _ * Open3.capture3("gh", "api", "-i", "rate_limit") >> ["HTTP/2.0 200 OK\nX-Oauth-Scopes: read:packages, repo\n\n{}\n", "", exit_status(0)]
    true
  end

  test "require_scope! raises MissingScopeError naming the gh auth refresh to run when a classic token lacks the scope" do
    Given
    auth = Dev::GhAuth.new

    When "a classic token without read:packages"
    auth.require_scope!(Dev::GhAuth::READ_PACKAGES)

    Then
    _ * Open3.capture3("gh", "api", "-i", "rate_limit") >> ["HTTP/2.0 200 OK\nX-Oauth-Scopes: repo\n\n{}\n", "", exit_status(0)]
    error = raises(Dev::GhAuth::MissingScopeError)
    error.message.include?("gh auth refresh -s read:packages")
  end

  test "require_scope! is a no-op for a token that reports no scopes: the registry call itself is the test" do
    Given
    auth = Dev::GhAuth.new

    When "an installation token"
    auth.require_scope!(Dev::GhAuth::WRITE_PACKAGES)

    Then "no refusal"
    _ * Open3.capture3("gh", "api", "-i", "rate_limit") >> ["HTTP/2.0 200 OK\n\n{}\n", "", exit_status(0)]
    true
  end

  test "a missing gh CLI raises GhMissingError naming the install" do
    Given
    auth = Dev::GhAuth.new

    When
    auth.token

    Then
    _ * Open3.capture3("gh", "auth", "token") >> raises(Errno::ENOENT)
    error = raises(Dev::GhAuth::GhMissingError)
    error.message.include?("brew install gh")
  end
end
