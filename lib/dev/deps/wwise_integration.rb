# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/credentials"
require_relative "integration"

module Dev
  module Deps
    # Lifecycle handler for the Wwise SDK dependency (wwise integration).
    #
    # Fills a wwise-cli cache directory on the host — the SDK package plus the
    # Unreal integration package the declaration names — and publishes it as
    # one version-keyed tree under the declared install_dir, so a build
    # container can mount the locked version read-only at wwise-cli's cache
    # path and run `wwise-cli integrate-ue --offline` with no credential in
    # the image build. Mirrors SteamIntegration: a tree in the store, never a
    # blob (the SDK is gigabytes), the published tree plus its marker is the
    # cache.
    #
    # The tree is laid out exactly as wwise-cli lays out its cache
    # (<cache-dir>/<product>/<version>/info.json), because wwise-cli is what
    # reads it later: install_dir/<sdk version>/wwise/<sdk version>/ and
    # install_dir/<sdk version>/unrealintegration/<integration version>/.
    #
    # Audiokinetic's downloads need an account login. The email and password
    # come from Dev::Credentials (WWISE_EMAIL / WWISE_PASSWORD, then the
    # stored credential, then a prompt that stores) and reach wwise-cli as
    # environment variables — viper's AutomaticEnv reads them as --email /
    # --password — never as argv, so no process listing shows them. The
    # chain is consulted only once the published-tree check and the tool
    # check have passed: a warm host never reads a credential.
    class WwiseIntegration < Integration
      extend T::Sig

      # The wwise-cli binary is not on PATH; it is a brew dep of the consumer.
      class WwiseCliMissingError < StandardError; end
      # wwise-cli failed, or reported success without leaving the cache entry
      # the published tree needs.
      class DownloadError < StandardError; end

      MARKER_FILE = ".dev-wwise"
      CREDENTIAL_NAMESPACE = "wwise"
      SDK_PRODUCT = "wwise"
      INTEGRATION_PRODUCT = "unrealintegration"
      CACHE_ENTRY_FILE = "info.json"

      # Install all wwise dependencies (in practice: one per project).
      #
      # @param dependencies [Array<Dependency>] wwise deps to install
      # @raise [PartialInstallError] if any dep failed to install
      sig { params(dependencies: T::Array[Dependency]).void }
      def install_all(dependencies)
        failures = collect_failures(dependencies) { |dep| install(dep) }
        raise PartialInstallError, failures if failures.any?
      end

      private

      # @param dep [Dependency]
      # @raise [WwiseCliMissingError] when wwise-cli is absent
      # @raise [DownloadError] when a download fails or leaves no cache entry
      sig { params(dep: Dependency).void }
      def install(dep)
        key = tree_key(dep, marker: MARKER_FILE)
        if (installed = store!.tree(key))
          puts ">>> #{dep.name}@#{dep.version} already installed at #{installed}"
          return
        end

        unless wwise_cli_available?
          raise WwiseCliMissingError,
            "#{dep.name} #{dep.version}: the wwise-cli CLI is not installed. " \
            "Declare it in dependencies.rb — group :build { brew \"wwise-cli\", tap: \"d3mlabs/d3mlabs\" } — " \
            "and run dev up."
        end

        env = credentials_env
        integration_version = dep.metadata.fetch("integration_version")
        published = store!.publish_tree(key) do |staging|
          puts ">>> Downloading Wwise SDK #{dep.version} into #{store!.tree_path(key)}"
          download_sdk(dep, staging, env)
          verify_cache_entry(staging, SDK_PRODUCT, dep.version)

          puts ">>> Fetching Wwise Unreal integration #{integration_version} for UE #{dep.metadata.fetch("ue")}"
          fetch_integration(dep, staging, env)
          verify_cache_entry(staging, INTEGRATION_PRODUCT, integration_version)
          staging
        end
        puts ">>> Installed #{dep.name}@#{dep.version} to #{published}"
      end

      # `wwise-cli download`: the SDK package(s) for the declared deployment
      # platforms. Each platform is its own --filter so the empty platform —
      # the one platform-independent SDK files carry, and whose omission
      # silently drops the base headers — survives as "DeploymentPlatforms=".
      #
      # @param dep [Dependency]
      # @param cache_dir [Pathname] the staging cache dir
      # @param env [Hash{String => String}] the credential environment
      # @raise [DownloadError] when wwise-cli fails
      sig { params(dep: Dependency, cache_dir: Pathname, env: T::Hash[String, String]).void }
      def download_sdk(dep, cache_dir, env)
        filters = dep.metadata.fetch("packages").flat_map { |package| ["--filter", "Packages=#{package}"] } +
          dep.metadata.fetch("deployment_platforms").flat_map { |platform| ["--filter", "DeploymentPlatforms=#{platform}"] }
        argv = ["wwise-cli", "--cache-dir", cache_dir.to_s, "download", "--sdk-version", dep.version.to_s] + filters
        return if run_wwise_cli(env, argv)

        raise DownloadError, "wwise-cli download failed for Wwise SDK #{dep.version}"
      end

      # `wwise-cli fetch-ue-integration`: the Unreal integration package for
      # the declared engine, cached without being integrated anywhere.
      #
      # @param dep [Dependency]
      # @param cache_dir [Pathname] the staging cache dir
      # @param env [Hash{String => String}] the credential environment
      # @raise [DownloadError] when wwise-cli fails
      sig { params(dep: Dependency, cache_dir: Pathname, env: T::Hash[String, String]).void }
      def fetch_integration(dep, cache_dir, env)
        integration_version = dep.metadata.fetch("integration_version")
        argv = [
          "wwise-cli", "--cache-dir", cache_dir.to_s,
          "fetch-ue-integration",
          "--integration-version", integration_version,
          "--ue", dep.metadata.fetch("ue"),
        ]
        return if run_wwise_cli(env, argv)

        raise DownloadError, "wwise-cli fetch-ue-integration failed for Wwise Unreal integration #{integration_version}"
      end

      # A wwise-cli run that exits 0 must have left the product's cache entry;
      # anything else means the published tree would be unusable offline.
      #
      # @param cache_dir [Pathname]
      # @param product [String] wwise-cli product name
      # @param version [String] product version
      # @raise [DownloadError] when the entry is missing
      sig { params(cache_dir: Pathname, product: String, version: String).void }
      def verify_cache_entry(cache_dir, product, version)
        entry = cache_dir / product / version / CACHE_ENTRY_FILE
        return if entry.file?

        raise DownloadError, "wwise-cli left no cache entry at #{product}/#{version}/#{CACHE_ENTRY_FILE}"
      end

      # The Audiokinetic login as wwise-cli's environment. Isolated so tests
      # can stub the credential chain.
      #
      # @return [Hash{String => String}] WWISE_EMAIL and WWISE_PASSWORD
      # @raise [Credentials::MissingCredentialError] on a non-interactive miss
      sig { returns(T::Hash[String, String]) }
      def credentials_env
        {
          "WWISE_EMAIL" => Credentials.resolve(
            namespace: CREDENTIAL_NAMESPACE, key: "email", env_var: "WWISE_EMAIL",
            prompt_label: "Wwise account email (the Audiokinetic login)",
          ),
          "WWISE_PASSWORD" => Credentials.resolve(
            namespace: CREDENTIAL_NAMESPACE, key: "password", env_var: "WWISE_PASSWORD",
            prompt_label: "Wwise account password",
          ),
        }
      end

      # wwise-cli boundary. Isolated so tests can stub it. stdin is /dev/null:
      # the credentials arrive in the environment, so any prompt wwise-cli
      # would still raise is a bug to fail on, never a hung job.
      #
      # @param env [Hash{String => String}] extra environment for the child
      # @param argv [Array<String>] the command line
      # @return [Boolean, nil] whether wwise-cli exited 0 (nil when it cannot run)
      sig { params(env: T::Hash[String, String], argv: T::Array[String]).returns(T.nilable(T::Boolean)) }
      def run_wwise_cli(env, argv)
        # T.unsafe on the receiver: Sorbet rejects splats of runtime-sized
        # arrays (error 7019) even when the array itself is T.unsafe; Kernel's
        # module function keeps the call public under an explicit receiver.
        T.unsafe(Kernel).system(env, *argv, in: File::NULL)
      end

      # @return [Boolean, nil] nil when the probe command cannot run
      sig { returns(T.nilable(T::Boolean)) }
      def wwise_cli_available?
        system("command -v wwise-cli >/dev/null 2>&1")
      end
    end
  end
end
