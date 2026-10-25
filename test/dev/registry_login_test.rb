# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/registry_login"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::RegistryLoginTest < Minitest::Test
  include SorbetHelper

  test "with logs the engine in to the registry with gh's token on stdin, yields, and logs out" do
    Given
    engine = FakeContainerEngine.new
    login = Dev::RegistryLogin.new(engine:, auth: gh_auth(token: "gho_secret", login: "jpduchesne"))
    order = []

    When
    result = login.with("ghcr.io") do
      order << :inside
      :done
    end

    Then "login, the block, logout — the token on stdin and never on argv"
    result == :done
    engine.runs == [["login", "ghcr.io", "-u", "jpduchesne", "--password-stdin"], ["logout", "ghcr.io"]]
    engine.run_stdins == ["gho_secret", nil]
    engine.runs.flatten.none? { |arg| arg.include?("gho_secret") }
    order == [:inside]
  end

  test "with logs out even when the block raises" do
    Given
    engine = FakeContainerEngine.new
    login = Dev::RegistryLogin.new(engine:, auth: gh_auth)

    When
    begin
      login.with("ghcr.io") { raise "pull failed" }
    rescue RuntimeError
      nil
    end

    Then
    engine.runs.last == ["logout", "ghcr.io"]
  end

  test "with checks the scope the operation needs before touching the engine: #{publish ? "publishing" : "pulling"}" do
    Given "a token that reports its scopes and lacks the one needed"
    engine = FakeContainerEngine.new
    auth = gh_auth
    auth.expects(:require_scope!).with(scope).raises(Dev::GhAuth::MissingScopeError, "lacks #{scope}")
    login = Dev::RegistryLogin.new(engine:, auth:)

    When
    login.with("ghcr.io", publish: publish) { flunk "the block must not run" }

    Then "the refusal is gh's, and no docker command ran"
    raises Dev::GhAuth::MissingScopeError
    engine.runs.empty?

    Where
    publish | scope
    false   | Dev::GhAuth::READ_PACKAGES
    true    | Dev::GhAuth::WRITE_PACKAGES
  end

  test "a failed login is a LoginFailedError naming the registry, and nothing is yielded" do
    Given
    engine = FakeContainerEngine.new(&method(:refuse_login))
    login = Dev::RegistryLogin.new(engine:, auth: gh_auth)

    When
    login.with("ghcr.io") { flunk "the block must not run" }

    Then
    error = raises(Dev::RegistryLogin::LoginFailedError)
    error.message.include?("ghcr.io")
  end

  private

  def refuse_login(argv)
    argv.first != "login"
  end

  def gh_auth(token: "t", login: "u")
    auth = typed_mock(Dev::GhAuth)
    auth.stubs(token: token, login: login)
    auth.stubs(:require_scope!)
    auth
  end
end
