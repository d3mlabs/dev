# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/wwise_integration"
require "dev/deps/local_store"
require "dev/deps/dependency"
require "tmpdir"

# WwiseIntegration with its two boundaries replaced: the wwise-cli process
# (records each invocation and writes the cache entries a real run leaves)
# and the credential chain (counts resolutions, never prompts). Everything
# else — marker idempotency, staging/publish, cache-layout verification —
# runs for real against the filesystem.
class FixtureWwiseIntegration < Dev::Deps::WwiseIntegration
  attr_reader :invocations, :credential_resolutions

  def initialize(cli_available: true, cli_succeeds: true, fetch_succeeds: true, writes_cache: true, **kwargs)
    super(**kwargs)
    @cli_available = cli_available
    @cli_succeeds = cli_succeeds
    @fetch_succeeds = fetch_succeeds
    @writes_cache = writes_cache
    @invocations = []
    @credential_resolutions = 0
  end

  private

  def wwise_cli_available? = @cli_available

  def credentials_env
    @credential_resolutions += 1
    { "WWISE_EMAIL" => "someone@example.com", "WWISE_PASSWORD" => "hunter2" }
  end

  def run_wwise_cli(env, argv)
    @invocations << { env: env, argv: argv }
    return false unless @cli_succeeds
    return false if argv.include?("fetch-ue-integration") && !@fetch_succeeds

    if @writes_cache
      cache_dir = argv[argv.index("--cache-dir") + 1]
      product, version =
        if argv.include?("download")
          ["wwise", argv[argv.index("--sdk-version") + 1]]
        else
          ["unrealintegration", argv[argv.index("--integration-version") + 1]]
        end
      entry = File.join(cache_dir, product, version)
      FileUtils.mkdir_p(entry)
      File.write(File.join(entry, "info.json"), '{"files":["x"],"groups":[]}')
    end
    true
  end
end unless defined?(FixtureWwiseIntegration)

transform!(RSpock::AST::Transformation)
class Dev::Deps::WwiseIntegrationTest < Minitest::Test
  SDK = "2023.1.14.8770"
  INTEGRATION = "2023.1.14.3555"

  def build_dependency(install_dir)
    Dev::Deps::Dependency.new(
      name: "Wwise", integration: :wwise, group: :build,
      version: SDK, hash: nil,
      metadata: {
        "install_dir" => install_dir,
        "integration_version" => INTEGRATION,
        "ue" => "5.6",
        "packages" => ["SDK"],
        "deployment_platforms" => ["Linux", ""],
      },
    )
  end

  def build_integration(dir, **opts)
    FixtureWwiseIntegration.new(repository: nil, store: Dev::Deps::LocalStore.new(data_root: dir), **opts)
  end

  test "install_all fills a wwise-cli cache in staging and publishes it under install_dir/<sdk version>/" do
    Given "a wwise dependency and a stubbed wwise-cli"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    integration = build_integration(dir)

    When "installing"
    integration.install_all([build_dependency(install_dir)])

    Then "the published tree is a cache dir holding both products, stamped, with no staging left"
    version_dir = File.join(install_dir, SDK)
    File.read(File.join(version_dir, ".dev-wwise")) == SDK
    File.exist?(File.join(version_dir, "wwise", SDK, "info.json"))
    File.exist?(File.join(version_dir, "unrealintegration", INTEGRATION, "info.json"))
    Dir.glob(File.join(install_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all runs download then fetch-ue-integration against one staging cache dir, credentials in the environment only" do
    Given "a wwise dependency and a stubbed wwise-cli"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    integration = build_integration(dir)

    When "installing"
    integration.install_all([build_dependency(install_dir)])
    download, fetch = integration.invocations.map { |call| call[:argv] }
    cache_dirs = integration.invocations.map { |call| call[:argv][call[:argv].index("--cache-dir") + 1] }.uniq

    Then "download selects packages and deployment platforms (the empty one included), fetch names the engine, " \
         "both share one staging cache dir, and the credential never enters argv"
    download.first(3) == ["wwise-cli", "--cache-dir", cache_dirs.first]
    download[3..] == [
      "download", "--sdk-version", SDK,
      "--filter", "Packages=SDK",
      "--filter", "DeploymentPlatforms=Linux",
      "--filter", "DeploymentPlatforms=",
    ]
    fetch[3..] == ["fetch-ue-integration", "--integration-version", INTEGRATION, "--ue", "5.6"]
    cache_dirs.size == 1
    cache_dirs.first.start_with?(File.join(install_dir, ".staging-"))
    integration.invocations.all? { |call| call[:env] == { "WWISE_EMAIL" => "someone@example.com", "WWISE_PASSWORD" => "hunter2" } }
    integration.invocations.none? { |call| call[:argv].join(" ").include?("hunter2") }
    integration.credential_resolutions == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all skips a published version without running wwise-cli or touching the credential chain" do
    Given "a version dir already stamped for the locked SDK"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    FileUtils.mkdir_p(File.join(install_dir, SDK))
    File.write(File.join(install_dir, SDK, ".dev-wwise"), SDK)
    integration = build_integration(dir)

    When "installing again"
    integration.install_all([build_dependency(install_dir)])

    Then
    integration.invocations.empty?
    integration.credential_resolutions == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises WwiseCliMissingError before resolving any credential when wwise-cli is absent" do
    Given "no wwise-cli on PATH"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    integration = build_integration(dir, cli_available: false)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([build_dependency(File.join(dir, "wwise"))])
    end

    Then "the failure names the brew declaration that provides the CLI, and nothing was prompted for"
    error.failures.first.last.is_a?(Dev::Deps::WwiseIntegration::WwiseCliMissingError)
    error.failures.first.last.message.include?('brew "wwise-cli", tap: "d3mlabs/d3mlabs"')
    integration.credential_resolutions == 0

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises DownloadError and publishes nothing when wwise-cli fails" do
    Given "a wwise-cli that exits non-zero"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    integration = build_integration(dir, cli_succeeds: false)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([build_dependency(install_dir)])
    end

    Then "the error is a DownloadError; no marker, no staging"
    error.failures.first.last.is_a?(Dev::Deps::WwiseIntegration::DownloadError)
    !File.exist?(File.join(install_dir, SDK, ".dev-wwise"))
    Dir.glob(File.join(install_dir, ".staging-*")).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "install_all raises DownloadError naming the integration when fetch-ue-integration fails after a good download" do
    Given "a wwise-cli whose download succeeds and whose fetch exits non-zero"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    integration = build_integration(dir, fetch_succeeds: false)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([build_dependency(install_dir)])
    end

    Then "the error names the integration version; nothing is published"
    error.failures.first.last.is_a?(Dev::Deps::WwiseIntegration::DownloadError)
    error.failures.first.last.message.include?("fetch-ue-integration failed for Wwise Unreal integration #{INTEGRATION}")
    !File.exist?(File.join(install_dir, SDK, ".dev-wwise"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the real boundaries: wwise-cli is found on PATH, run with the ENV credentials in its environment and stdin closed" do
    Given "a wwise-cli script on PATH that records how it was called and writes the cache entries, and credentials in ENV"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    record = File.join(dir, "calls.log")
    File.write(File.join(bin_dir, "wwise-cli"), <<~SH)
      #!/bin/sh
      printf 'argv:%s\\nemail:%s\\npassword:%s\\nstdin:%s\\n' "$*" "$WWISE_EMAIL" "$WWISE_PASSWORD" "$(cat)" >> "#{record}"
      cache="$2"
      if [ "$3" = download ]; then entry="$cache/wwise/$5"; else entry="$cache/unrealintegration/$5"; fi
      mkdir -p "$entry" && echo '{"files":["x"],"groups":[]}' > "$entry/info.json"
    SH
    File.chmod(0o755, File.join(bin_dir, "wwise-cli"))
    saved = %w[PATH WWISE_EMAIL WWISE_PASSWORD].to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV["PATH"] = "#{bin_dir}#{File::PATH_SEPARATOR}#{saved["PATH"]}"
    ENV["WWISE_EMAIL"] = "env@example.com"
    ENV["WWISE_PASSWORD"] = "from-env"
    integration = Dev::Deps::WwiseIntegration.new(repository: nil, store: Dev::Deps::LocalStore.new(data_root: dir))

    When "installing"
    integration.install_all([build_dependency(install_dir)])
    calls = File.read(record)

    Then "the tree is published, both calls saw the ENV credentials, and stdin read EOF"
    File.read(File.join(install_dir, SDK, ".dev-wwise")) == SDK
    calls.scan("argv:").size == 2
    calls.scan("email:env@example.com").size == 2
    calls.scan("password:from-env").size == 2
    calls.scan("stdin:\n").size == 2

    Cleanup
    saved.each { |key, value| ENV[key] = value }
    FileUtils.rm_rf(dir)
  end

  test "install_all raises DownloadError when wwise-cli exits 0 but leaves no cache entry behind" do
    Given "a wwise-cli that succeeds without writing"
    dir = Dir.mktmpdir("dev-wwise-int-test-")
    install_dir = File.join(dir, "wwise")
    integration = build_integration(dir, writes_cache: false)

    When "installing"
    error = assert_raises(Dev::Deps::Integration::PartialInstallError) do
      integration.install_all([build_dependency(install_dir)])
    end

    Then "the missing entry is named"
    error.failures.first.last.is_a?(Dev::Deps::WwiseIntegration::DownloadError)
    error.failures.first.last.message.include?("wwise/#{SDK}/info.json")
    !File.exist?(File.join(install_dir, SDK, ".dev-wwise"))

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
