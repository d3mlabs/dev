# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/registry_credential"

transform!(RSpock::AST::Transformation)
class Dev::RegistryCredentialTest < Minitest::Test
  include SorbetHelper

  test "with DEV_REGISTRY_TOKEN set, the token is the env's, the login anonymous, and gh is never asked" do
    Given "a job that names its registry token"
    auth = typed_mock(Dev::GhAuth)
    auth.expects(:token).never
    auth.expects(:login).never
    credential = Dev::RegistryCredential.new(auth:, env: { "DEV_REGISTRY_TOKEN" => "ghs_job" })

    Expect
    credential.token == "ghs_job"
    credential.login == Dev::GhAuth::ANONYMOUS_LOGIN
    credential.explicit?
  end

  test "an explicit token skips the scope check: the registry's answer is the only test it admits" do
    Given "gh's token, were it asked, lacks the scope"
    auth = typed_mock(Dev::GhAuth)
    auth.stubs(:require_scope!).raises(Dev::GhAuth::MissingScopeError, "lacks write:packages")
    credential = Dev::RegistryCredential.new(auth:, env: { "DEV_REGISTRY_TOKEN" => "ghs_job" })

    When
    credential.require_scope!(Dev::GhAuth::WRITE_PACKAGES)

    Then "no refusal (the When would have raised): gh's scopes say nothing about a token that is not gh's"
    credential.explicit?
  end

  test "with DEV_REGISTRY_TOKEN #{state}, the credential is gh's: token, login and scope check" do
    Given "a host with one identity"
    auth = typed_mock(Dev::GhAuth)
    auth.stubs(token: "gho_host", login: "jpduchesne")
    auth.expects(:require_scope!).with(Dev::GhAuth::READ_PACKAGES)
    credential = Dev::RegistryCredential.new(auth:, env:)

    When
    credential.require_scope!(Dev::GhAuth::READ_PACKAGES)

    Then
    credential.token == "gho_host"
    credential.login == "jpduchesne"
    !credential.explicit?

    Where
    state   | env
    "unset" | {}
    "empty" | { "DEV_REGISTRY_TOKEN" => "" }
  end
end
