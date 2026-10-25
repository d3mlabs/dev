# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/gh_auth"

transform!(RSpock::AST::Transformation)
class Dev::GhAuthTest < Minitest::Test
  include SorbetHelper

  test "token is gh's token, stripped of its trailing newline" do
    Given "gh holds a token"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["auth", "token"], out: "gho_abc123\n")

    Expect
    auth.token == "gho_abc123"
  end

  test "token raises NotAuthenticatedError, naming gh auth login, when gh has none" do
    Given "no gh login"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["auth", "token"], out: "", err: "no oauth token found for github.com — run gh auth login", ok: false)

    When
    auth.token

    Then
    error = raises(Dev::GhAuth::NotAuthenticatedError)
    error.message.include?("gh auth login")
  end

  test "login is the authenticated user's handle, asked once" do
    Given "gh answers the user query"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "user", "--jq", ".login"], out: "jpduchesne\n").once

    Expect "the same answer twice without a second call"
    auth.login == "jpduchesne"
    auth.login == "jpduchesne"
  end

  test "login falls back to a placeholder when the token cannot read /user (a workflow's installation token)" do
    Given "gh refuses the user query"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "user", "--jq", ".login"], out: "", err: "HTTP 403: Resource not accessible by integration", ok: false)

    Expect "a registry login still has a username to send; GHCR ignores it"
    auth.login == Dev::GhAuth::ANONYMOUS_LOGIN
  end

  test "scopes are parsed off the X-OAuth-Scopes header of an authenticated response" do
    Given "a classic token's response headers"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "-i", "rate_limit"], out: <<~HTTP)
      HTTP/2.0 200 OK
      Content-Type: application/json; charset=utf-8
      X-Oauth-Scopes: gist, read:org, read:packages, repo
      X-Ratelimit-Limit: 5000

      {"resources":{}}
    HTTP

    Expect
    auth.scopes == ["gist", "read:org", "read:packages", "repo"]
  end

  test "scopes are empty when the response carries no scopes header (installation and fine-grained tokens)" do
    Given "a response without the header"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "-i", "rate_limit"], out: "HTTP/2.0 200 OK\nContent-Type: application/json\n\n{}\n")

    Expect
    auth.scopes == []
    !auth.scopes_reported?
  end

  test "require_scope! passes when the token carries the scope" do
    Given
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "-i", "rate_limit"], out: "HTTP/2.0 200 OK\nX-Oauth-Scopes: read:packages, repo\n\n{}\n")

    When
    auth.require_scope!(Dev::GhAuth::READ_PACKAGES)

    Then "no refusal"
    true
  end

  test "require_scope! raises MissingScopeError naming the gh auth refresh to run when a classic token lacks the scope" do
    Given "a classic token without read:packages"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "-i", "rate_limit"], out: "HTTP/2.0 200 OK\nX-Oauth-Scopes: repo\n\n{}\n")

    When
    auth.require_scope!(Dev::GhAuth::READ_PACKAGES)

    Then
    error = raises(Dev::GhAuth::MissingScopeError)
    error.message.include?("gh auth refresh -s read:packages")
  end

  test "require_scope! is a no-op for a token that reports no scopes: the registry call itself is the test" do
    Given "an installation token"
    auth = Dev::GhAuth.new
    stub_gh(auth, ["api", "-i", "rate_limit"], out: "HTTP/2.0 200 OK\n\n{}\n")

    When
    auth.require_scope!(Dev::GhAuth::WRITE_PACKAGES)

    Then "no refusal"
    true
  end

  test "a missing gh CLI raises GhMissingError naming the install" do
    Given
    auth = Dev::GhAuth.new
    Open3.stubs(:capture3).with("gh", "auth", "token").raises(Errno::ENOENT)

    When
    auth.token

    Then
    error = raises(Dev::GhAuth::GhMissingError)
    error.message.include?("brew install gh")
  end

  private

  def stub_gh(_auth, args, out:, err: "", ok: true)
    Open3.stubs(:capture3).with("gh", *args).returns([out, err, stub(success?: ok)])
  end
end
