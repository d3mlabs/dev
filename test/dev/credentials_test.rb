# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/credentials"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::CredentialsTest < Minitest::Test
  test "resolve returns ENV var when set" do
    Given "an environment variable with the credential"
    env_key = "TEST_CRED_#{Process.pid}"
    ENV[env_key] = "env-value"

    When "resolving the credential"
    result = Dev::Credentials.resolve(
      namespace: "test", key: "token",
      env_var: env_key,
      prompt_label: "Test token",
      create_url: "https://example.com",
    )

    Then "it returns the ENV value without touching storage"
    result == "env-value"

    Cleanup
    ENV.delete(env_key)
  end

  test "resolve prefers ENV over stored credential" do
    Given "a credential stored on disk and an ENV override"
    tmpdir = Dir.mktmpdir("credentials-test-")
    env_key = "TEST_CRED_#{Process.pid}"
    ENV[env_key] = "env-value"
    ENV["XDG_CONFIG_HOME"] = tmpdir

    Dev::Credentials.store_to_file("test", "token", "file-value")

    When "resolving the credential"
    result = Dev::Credentials.resolve(
      namespace: "test", key: "token",
      env_var: env_key,
      prompt_label: "Test token",
      create_url: "https://example.com",
    )

    Then "ENV takes precedence"
    result == "env-value"

    Cleanup
    ENV.delete(env_key)
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "resolve_build_args resolves each arg via its env var override" do
    Given "build args whose env vars are set"
    email_var = "TEST_WWISE_EMAIL_#{Process.pid}"
    password_var = "TEST_WWISE_PASSWORD_#{Process.pid}"
    ENV[email_var] = "me@example.com"
    ENV[password_var] = "s3cret"
    build_args = { email_var => "wwise/email", password_var => "wwise/password" }

    When "resolving build args"
    result = Dev::Credentials.resolve_build_args(build_args)

    Then "each arg name maps to its resolved value"
    result == { email_var => "me@example.com", password_var => "s3cret" }

    Cleanup
    ENV.delete(email_var)
    ENV.delete(password_var)
  end

  test "store_to_file creates credentials file with 0600 permissions" do
    Given "a temporary config directory"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir

    When "storing a credential"
    Dev::Credentials.store_to_file("curseforge", "api_key", "cf-secret-123")

    Then "the file exists with correct content and permissions"
    path = File.join(tmpdir, "dev", "credentials.yml")
    assert File.exist?(path)
    creds = YAML.safe_load_file(path)
    creds.dig("curseforge", "api_key") == "cf-secret-123"
    (File.stat(path).mode & 0o777) == 0o600

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "store_to_file merges with existing namespaces" do
    Given "a credentials file with an existing namespace"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir

    Dev::Credentials.store_to_file("github", "token", "ghp_existing")

    When "storing a credential under a different namespace"
    Dev::Credentials.store_to_file("curseforge", "api_key", "cf-new")

    Then "both namespaces are preserved"
    path = File.join(tmpdir, "dev", "credentials.yml")
    creds = YAML.safe_load_file(path)
    creds.dig("github", "token") == "ghp_existing"
    creds.dig("curseforge", "api_key") == "cf-new"

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "load_from_file returns stored value" do
    Given "a credentials file with a stored credential"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir
    Dev::Credentials.store_to_file("curseforge", "api_key", "cf-stored")

    When "loading the credential"
    result = Dev::Credentials.load_from_file("curseforge", "api_key")

    Then "it returns the stored value"
    result == "cf-stored"

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "load_from_file returns nil when file does not exist" do
    Given "no credentials file"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir

    When "loading a credential"
    result = Dev::Credentials.load_from_file("curseforge", "api_key")

    Then "it returns nil"
    result.nil?

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "load_from_file returns nil for missing namespace" do
    Given "a credentials file without the requested namespace"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir
    Dev::Credentials.store_to_file("github", "token", "ghp_xxx")

    When "loading a credential from a different namespace"
    result = Dev::Credentials.load_from_file("curseforge", "api_key")

    Then "it returns nil"
    result.nil?

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "load_from_keychain returns value from security CLI" do
    Given "a keychain entry"
    stdout = "my-secret-key\n"
    Open3.stubs(:capture3)
         .with("security", "find-generic-password",
               "-a", "d3mlabs/dev", "-s", "curseforge/api_key", "-w")
         .returns([stdout, "", stub(success?: true)])

    When "loading from keychain"
    result = Dev::Credentials.load_from_keychain("curseforge", "api_key")

    Then "it returns the chomped value"
    result == "my-secret-key"
  end

  test "load_from_keychain returns nil when entry not found" do
    Given "no keychain entry"
    Open3.stubs(:capture3)
         .with("security", "find-generic-password",
               "-a", "d3mlabs/dev", "-s", "curseforge/api_key", "-w")
         .returns(["", "security: SecKeychainSearchCopyNext", stub(success?: false)])

    When "loading from keychain"
    result = Dev::Credentials.load_from_keychain("curseforge", "api_key")

    Then "it returns nil"
    result.nil?
  end

  test "store_to_keychain calls security CLI with correct arguments" do
    When "storing to keychain"
    Dev::Credentials.store_to_keychain("curseforge", "api_key", "cf-secret")

    Then "security add-generic-password is called with -U flag"
    1 * Kernel.system(
      "security", "add-generic-password",
      "-U",
      "-a", "d3mlabs/dev",
      "-s", "curseforge/api_key",
      "-w", "cf-secret",
      out: File::NULL, err: File::NULL,
    )
  end

  test "prompt_and_store raises MissingCredentialError in non-TTY" do
    Given "a non-TTY stdin"
    $stdin.stubs(:tty?).returns(false)

    When "prompting for a credential"
    Dev::Credentials.prompt_and_store(
      "curseforge", "api_key", "CF_API_KEY",
      "CurseForge API key", "https://console.curseforge.com",
    )

    Then "it raises with setup instructions"
    error = raises Dev::Credentials::MissingCredentialError
    assert_includes error.message, "CurseForge API key"
    assert_includes error.message, "https://console.curseforge.com"
    assert_includes error.message, "gh secret set CF_API_KEY"
  end

  test "credentials_path respects XDG_CONFIG_HOME" do
    Given "a custom XDG_CONFIG_HOME"
    ENV["XDG_CONFIG_HOME"] = "/custom/config"

    When "getting the credentials path"
    path = Dev::Credentials.credentials_path

    Then "it uses the custom config home"
    path == "/custom/config/dev/credentials.yml"

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
  end

  test "credentials_path defaults to ~/.config" do
    Given "no XDG_CONFIG_HOME set"
    original = ENV.delete("XDG_CONFIG_HOME")

    When "getting the credentials path"
    path = Dev::Credentials.credentials_path

    Then "it defaults to ~/.config/dev/credentials.yml"
    path == File.join(Dir.home, ".config", "dev", "credentials.yml")

    Cleanup
    ENV["XDG_CONFIG_HOME"] = original if original
  end

  test "store_to_file creates parent directory with 0700 permissions" do
    Given "a temporary config directory"
    tmpdir = Dir.mktmpdir("credentials-test-")
    ENV["XDG_CONFIG_HOME"] = tmpdir

    When "storing a credential"
    Dev::Credentials.store_to_file("curseforge", "api_key", "cf-secret")

    Then "the parent directory has owner-only permissions"
    dir = File.join(tmpdir, "dev")
    (File.stat(dir).mode & 0o777) == 0o700

    Cleanup
    ENV.delete("XDG_CONFIG_HOME")
    FileUtils.rm_rf(tmpdir)
  end

  test "keychain_service builds namespaced service name" do
    When "building a keychain service name"
    service = Dev::Credentials.keychain_service("curseforge", "api_key")

    Then "it returns namespace/key"
    service == "curseforge/api_key"
  end
end
