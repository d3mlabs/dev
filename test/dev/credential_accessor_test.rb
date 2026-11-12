# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/credential_accessor"
require "support/recording_ui"
require "stringio"

# A stand-in credential provider capturing the resolve arguments, so the
# accessor's dispatch + ENV-var derivation are tested without the real
# provider's storage behind it.
class FakeCredentials
  attr_reader :last_resolve

  def initialize(value:)
    @value = value
    @last_resolve = nil
  end

  def resolve(namespace:, key:, env_var:, prompt_label:, ui:, create_url: nil)
    @last_resolve = { namespace:, key:, env_var:, prompt_label:, ui:, create_url: }
    @value
  end
end unless defined?(FakeCredentials)

transform!(RSpock::AST::Transformation)
class Dev::CredentialAccessorTest < Minitest::Test
  test "cred get resolves the namespace/key and prints the value" do
    Given "an accessor over a provider that returns a value"
    creds = FakeCredentials.new(value: "s3cr3t")
    accessor = Dev::CredentialAccessor.new(credentials: creds)
    out = StringIO.new
    ui = RecordingUi.new

    When "getting a credential"
    accessor.get(["staging", "ssh_key"], ui: ui, out: out)

    Then "the value is the whole payload, the provider was asked for that namespace/key, and handed the Ui to prompt at"
    out.string == "s3cr3t\n"
    ui.rows == []
    creds.last_resolve[:namespace] == "staging"
    creds.last_resolve[:key] == "ssh_key"
    creds.last_resolve[:ui].equal?(ui)

    Cleanup
    nil
  end

  test "cred get derives the conventional ENV override name" do
    Given "an accessor over a recording provider"
    creds = FakeCredentials.new(value: "v")
    accessor = Dev::CredentialAccessor.new(credentials: creds)

    When "getting a credential whose key has separators"
    accessor.get(["wwise", "token"], ui: RecordingUi.new, out: StringIO.new)

    Then "the env_var is the upcased namespace_key"
    creds.last_resolve[:env_var] == "WWISE_TOKEN"

    Cleanup
    nil
  end

  test "cred get with trailing arguments raises UsageError" do
    Given "an accessor"
    accessor = Dev::CredentialAccessor.new(credentials: FakeCredentials.new(value: "v"))

    When "getting with an extra argument"
    accessor.get(["staging", "ssh_key", "junk"], ui: RecordingUi.new, out: StringIO.new)

    Then
    raises Dev::CredentialAccessor::UsageError

    Cleanup
    nil
  end

  test "cred get without a key raises UsageError" do
    Given "an accessor"
    accessor = Dev::CredentialAccessor.new(credentials: FakeCredentials.new(value: "v"))

    When "getting with a namespace but no key"
    accessor.get(["staging"], ui: RecordingUi.new, out: StringIO.new)

    Then
    raises Dev::CredentialAccessor::UsageError

    Cleanup
    nil
  end
end
