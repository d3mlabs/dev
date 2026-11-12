# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/credentials"
require "dev/ui"
require "dev/lifecycle/channel"
require "dev/lifecycle/platform"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/shell"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require "dev/lifecycle/unpacker"
require "dev/platform"
require_relative "artifact_store"
require_relative "build_patch_tool"
require_relative "egs_channel_options"
require_relative "egs_integration"
require_relative "local_store"
require_relative "lockfile"

module Dev
  module Deps
    # The `egs` integration's write side (dev#192 K5, dev#426): the
    # Publisher behind the `deploy egs` channel a project pinning
    # BuildPatchTool gets. The Epic Games Store takes no archive: its
    # BuildPatchTool reads a **build root** — so each shipment's archive is
    # unpacked into one in the channel's scratch — and registers it as a
    # binary of the artifact the channel's `egs:` options name for that
    # build (`UploadBinary`: the build id as Epic's BuildVersion, the
    # launch app and args from the options, a cloud dir in the scratch the
    # tool diffs the upload against), then labels it for the track
    # (`LabelBinary`: `Live` for a release, the testing label for a working
    # artifact — a label is what keeps Epic's cleanup from deleting the
    # binary after a week). The archive is read-only input; the receipt
    # names the versions registered and the label they got.
    #
    # The tool is the lock's: the one `egs` pin, read from the project's
    # lock and found in the store where `dev up` installed it (the same
    # lookup `dev deps path egs BuildPatchTool` answers). EGS serves
    # Windows and Mac players, so a linux64 or a platform-less build is
    # refused with the platforms Epic labels.
    #
    # **Credentials.** The product's client comes from the Credentials
    # provider, never dev.yml: `egs/client_id` (`EGS_CLIENT_ID`) and
    # `egs/client_secret` (`EGS_CLIENT_SECRET`), the pair the Dev Portal
    # issues for BuildPatchTool. The secret reaches the tool through the
    # environment variable `-ClientSecretEnvVar` names, Epic's own
    # recommendation, so it is on no command line.
    class EgsPublisher
      extend T::Sig
      include Lifecycle::Publisher

      # The lock pins no `egs` dependency — nothing contributed this
      # channel, so reaching this is a wiring bug.
      class NoToolPinnedError < StandardError; end

      # The locked tool is not in the store yet.
      class ToolNotInstalledError < RuntimeError; end

      # A build for a platform Epic's launcher does not serve.
      class UnsupportedPlatformError < ArgumentError; end

      # BuildPatchTool ended other than with exit 0.
      class UploadFailedError < RuntimeError; end

      CREDENTIAL_NAMESPACE = "egs"
      BUILDS_DIR = "builds"
      CLOUD_DIR = "cloud"
      CREDENTIALS_URL = "https://dev.epicgames.com/docs/epic-games-store/publishing-tools/uploading-binaries/bpt-instructions-160"

      # Epic's platform names for `LabelBinary`, by dev's platform id.
      LABEL_PLATFORMS = T.let(
        { Lifecycle::Platform::Win64 => "Windows", Lifecycle::Platform::Macos => "Mac" }.freeze,
        T::Hash[Lifecycle::Platform, String],
      )

      # @param project_root [Pathname] the checkout whose lock pins the tool
      # @param store [ArtifactStore] where the tool is installed
      # @param host [String] Dev::Platform.os — which binary in the tree is this machine's
      # @param unpacker [Lifecycle::Unpacker] what turns an archive into a build root
      # @param ui [Ui] the terminal a first-time credential is onboarded at
      sig { params(project_root: Pathname, store: ArtifactStore, host: String, unpacker: Lifecycle::Unpacker, ui: Ui).void }
      def initialize(project_root:, store: LocalStore.new, host: Dev::Platform.os, unpacker: Lifecycle::Unpacker.new, ui: NoUi.new)
        @lockfile = T.let(Lockfile.new(dir: project_root), Lockfile)
        @store = store
        @host = host
        @unpacker = unpacker
        @ui = ui
      end

      # Register each shipment as a binary of its artifact and label it for
      # the track.
      #
      # @param shipments [Array<Lifecycle::Shipment>] one per artifact
      # @param channel [Lifecycle::Channel] carries the `egs:` options
      # @param track [Lifecycle::Track] decides the label
      # @param scratch [Pathname] where the build roots and the tool's cloud dir live
      # @return [Lifecycle::Receipt] the versions registered and their label
      # @raise [EgsChannelOptions::MissingOptionError] and its siblings, for the options
      # @raise [UnsupportedPlatformError]
      # @raise [NoToolPinnedError]
      # @raise [ToolNotInstalledError]
      # @raise [Lifecycle::Unpacker::UnpackFailedError] and its siblings, for an archive
      # @raise [Credentials::MissingCredentialError] with no client and no terminal
      # @raise [UploadFailedError]
      sig do
        override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname)
          .returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        options = EgsChannelOptions.parse(channel)
        label = options.label_for(track)
        uploads = shipments.map { |shipment| [shipment, options.artifact_for(shipment.build), label_platform(shipment)] }
        tool = tool_binary
        client_id, env = client
        scratch.mkpath

        uploads.each do |shipment, artifact, platform|
          build_root = @unpacker.unpack(shipment.archive, into: scratch / BUILDS_DIR / shipment.name)
          common = common_arguments(options, artifact, client_id, shipment)
          run(tool, common + upload_arguments(build_root, scratch / CLOUD_DIR / artifact.id, artifact), env:, what: "upload of #{shipment}")
          run(tool, common + ["-mode=LabelBinary", "-Label=#{label}", "-Platform=#{platform}"], env:, what: "labelling of #{shipment}")
        end
        Lifecycle::Receipt.new(summary: "egs #{uploads.map { |shipment, artifact, _| "#{shipment.build_id} → artifact #{artifact.id}" }.join(", ")} labelled #{label}")
      end

      private

      # @param shipment [Lifecycle::Shipment]
      # @return [String] Epic's platform name
      # @raise [UnsupportedPlatformError]
      sig { params(shipment: Lifecycle::Shipment).returns(String) }
      def label_platform(shipment)
        platform = shipment.build.platform
        named = platform.nil? ? nil : LABEL_PLATFORMS[platform]
        return named unless named.nil?

        raise UnsupportedPlatformError,
          "#{shipment.name}: the Epic Games Store serves #{LABEL_PLATFORMS.keys.map(&:serialize).join(" and ")} builds, not " \
            "#{platform.nil? ? "a build with no platform" : platform.to_s} — narrow the channel's `targets:`"
      end

      # The locked tool's binary for this host.
      #
      # @return [Pathname]
      # @raise [NoToolPinnedError]
      # @raise [ToolNotInstalledError]
      sig { returns(Pathname) }
      def tool_binary
        dep = @lockfile.read.find { |pin| pin.integration == :egs }
        raise NoToolPinnedError, "the lock pins no egs dependency — declare `egs \"#{BuildPatchTool::NAME}\"` in dependencies.rb" if dep.nil?

        key = EgsIntegration.tree_key(dep)
        tree = @store.tree(key)
        raise ToolNotInstalledError, "#{dep.name} is not installed at #{@store.tree_path(key)} — run dev up" if tree.nil?

        BuildPatchTool.binary(tree, host: @host)
      end

      # The client id, and the environment carrying the secret.
      #
      # @return [Array(String, Hash{String => String})]
      # @raise [Credentials::MissingCredentialError]
      sig { returns([String, T::Hash[String, String]]) }
      def client
        client_id = Credentials.resolve(
          namespace: CREDENTIAL_NAMESPACE, key: "client_id", env_var: "EGS_CLIENT_ID",
          prompt_label: "Epic Games Store client id (the product's BuildPatchTool credentials)", create_url: CREDENTIALS_URL, ui: @ui,
        )
        secret = Credentials.resolve(
          namespace: CREDENTIAL_NAMESPACE, key: "client_secret", env_var: "EGS_CLIENT_SECRET",
          prompt_label: "Epic Games Store client secret", create_url: CREDENTIALS_URL, ui: @ui,
        )
        [client_id, { BuildPatchTool::CLIENT_SECRET_ENV_VAR => secret }]
      end

      # The arguments every mode takes: who, which artifact, which version.
      #
      # @param options [EgsChannelOptions]
      # @param artifact [EgsChannelOptions::Artifact]
      # @param client_id [String]
      # @param shipment [Lifecycle::Shipment]
      # @return [Array<String>]
      sig do
        params(options: EgsChannelOptions, artifact: EgsChannelOptions::Artifact, client_id: String, shipment: Lifecycle::Shipment)
          .returns(T::Array[String])
      end
      def common_arguments(options, artifact, client_id, shipment)
        [
          "-OrganizationId=#{options.organization}",
          "-ProductId=#{options.product}",
          "-ArtifactId=#{artifact.id}",
          "-ClientId=#{client_id}",
          "-ClientSecretEnvVar=#{BuildPatchTool::CLIENT_SECRET_ENV_VAR}",
          "-BuildVersion=#{shipment.build_id}",
        ]
      end

      # @param build_root [Pathname]
      # @param cloud_dir [Pathname]
      # @param artifact [EgsChannelOptions::Artifact]
      # @return [Array<String>]
      sig { params(build_root: Pathname, cloud_dir: Pathname, artifact: EgsChannelOptions::Artifact).returns(T::Array[String]) }
      def upload_arguments(build_root, cloud_dir, artifact)
        cloud_dir.mkpath
        [
          "-mode=UploadBinary",
          "-BuildRoot=#{build_root}",
          "-CloudDir=#{cloud_dir}",
          "-AppLaunch=#{artifact.launch}",
          "-AppArgs=#{artifact.args}",
        ]
      end

      # @param tool [Pathname]
      # @param arguments [Array<String>]
      # @param env [Hash{String => String}]
      # @param what [String] the step, for the message
      # @return [void]
      # @raise [UploadFailedError]
      sig { params(tool: Pathname, arguments: T::Array[String], env: T::Hash[String, String], what: String).void }
      def run(tool, arguments, env:, what:)
        out, err, status = BuildPatchTool.run(tool, arguments, env:)
        return if status.success?

        raise UploadFailedError, "BuildPatchTool #{what} #{Lifecycle::Shell.describe(status)}: #{(err + out).strip.lines.last(5).join}"
      end
    end
  end
end
