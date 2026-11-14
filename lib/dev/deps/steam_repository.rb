# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/credentials"
require "dev/ui"
require "dev/lifecycle/channel"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/shell"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require "dev/lifecycle/unpacker"
require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"
require_relative "steam_app_build"
require_relative "steam_channel_options"
require_relative "steam_cmd"

module Dev
  module Deps
    # Reports a Steam application's universe (e.g. the Satisfactory Dedicated
    # Server): every branch's current buildid.
    #
    # The "version" is the Steam buildid, resolved via SteamCMD's
    # +app_info_print. There is no content hash — Steam exposes no stable
    # per-build digest, so integrity is delegated to SteamCMD's
    # `app_update … validate` at install time (the same nil-hash shape brew
    # casks use).
    #
    # Declared in dependencies.rb as:
    #   steam "SatisfactoryServer", app: 1690800
    #
    # Also the `steam` integration's write side: the Publisher behind the
    # `deploy steam` channel a project pinning a steam dependency gets.
    # Both directions are one client and one auth: steamcmd, `app_update`
    # to read a depot and `run_app_build` to write one. The upload is not a
    # file but a build: each archive
    # is unpacked into a depot's content root in the channel's scratch,
    # the app and depot build scripts are written there (SteamAppBuild —
    # depot ids from the channel's `steam:` options, the branch from the
    # track), and steamcmd runs the build under the Steam build account.
    # The archives are read-only input; the BuildID Steam assigns is the
    # receipt.
    #
    # **Credentials.** The build account comes from the Credentials
    # provider, never dev.yml: `steam/username` (`STEAM_USERNAME`) is
    # required; `steam/password` (`STEAM_PASSWORD`) is used when stored
    # and otherwise the login relies on the token steamcmd cached from an
    # earlier interactive login — Steamworks' own CI recipe, since a
    # password login issues a fresh Steam Guard challenge. Both ride a
    # steamcmd script file (`+runscript`) created `0600` in the scratch and
    # removed after the run, so the password is on no command line.
    class SteamRepository < Repository
      extend T::Sig
      include Lifecycle::Publisher

      # steamcmd ended other than with exit 0, or Steam refused the build.
      class UploadFailedError < RuntimeError; end

      # steamcmd exited 0 without reporting the BuildID the build got.
      class BuildIdNotReportedError < RuntimeError; end

      CREDENTIAL_NAMESPACE = "steam"
      DEPOTS_DIR = "depots"
      OUTPUT_DIR = "output"
      LOGIN_SCRIPT = "steamcmd.txt"
      BUILD_ACCOUNT_URL = "https://partner.steamgames.com/doc/sdk/uploading#Build_Account"
      BUILD_ID_PATTERN = /Successfully finished AppID \d+ build \(BuildID (\d+)\)/

      # @param unpacker [Lifecycle::Unpacker] what turns an archive into a content root
      # @param ui [Ui] the terminal a first-time build account is onboarded at
      sig { params(unpacker: Lifecycle::Unpacker, ui: Ui).void }
      def initialize(unpacker: Lifecycle::Unpacker.new, ui: NoUi.new)
        super()
        @unpacker = unpacker
        @ui = ui
      end

      # Report a Steam app's universe: the current buildid of every branch,
      # one version per branch.
      #
      # Steam exposes no build history, but branch tips ARE enumerable: one
      # +app_info_print call reports every branch's current buildid.
      # The branch a buildid is the tip of rides metadata as
      # a fact for SteamScheme's branch selection. No digest: Steam publishes
      # no stable per-build hash; integrity is SteamCMD's app_update …
      # validate at install.
      #
      # @param id [PackageId] source is the Steam app id
      # @return [Package] one version per branch
      # @raise [SteamCmd::SteamCmdError] if querying the app fails
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        app = T.must(id.source)
        versions = resolve_branches(app).map do |branch, build_id|
          PackageVersion.new(
            version: build_id,
            metadata: { "app" => app, "branch" => branch },
            # Steam depots are self-contained by construction: SteamCMD
            # delivers the complete installed tree.
            declarations: Declarations::Resolved.new([]),
          )
        end
        raise PackageNotFoundError, "no branches with a buildid for Steam app #{app}" if versions.empty?

        Package.new(id: id, versions: versions)
      end

      # Upload the shipments as one Steam build: one depot per archive, the
      # branch the track names set live when Steam allows it.
      #
      # @param shipments [Array<Lifecycle::Shipment>] one per depot
      # @param channel [Lifecycle::Channel] carries the `steam:` options
      # @param track [Lifecycle::Track] testing → the beta branch, live → the default one
      # @param scratch [Pathname] where the content roots, the scripts and steamcmd's output live
      # @return [Lifecycle::Receipt] the BuildID, the depots and the branch
      # @raise [SteamChannelOptions::MissingOptionError] and its siblings, for the options
      # @raise [Lifecycle::Unpacker::UnpackFailedError] and its siblings, for an archive
      # @raise [Credentials::MissingCredentialError] with no build account and no terminal
      # @raise [UploadFailedError]
      # @raise [BuildIdNotReportedError]
      sig do
        override.params(shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname)
          .returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        options = SteamChannelOptions.parse(channel)
        branch = options.branch_for(track)
        depots = shipments.to_h { |shipment| [options.depot_for(shipment.build), shipment] }
        scratch.mkpath

        content_roots = depots.to_h do |depot, shipment|
          [depot, @unpacker.unpack(shipment.archive, into: scratch / DEPOTS_DIR / depot.to_s)]
        end
        app_build = SteamAppBuild.new(
          app: options.app,
          desc: shipments.join(", "),
          depots: content_roots,
          build_output: scratch / OUTPUT_DIR,
          set_live: options.default_branch?(branch) ? nil : branch,
        )
        build_id = run_app_build(app_build.write(scratch), scratch)
        Lifecycle::Receipt.new(summary: summary(build_id, options, branch, content_roots.keys))
      end

      private

      # Isolated so tests can stub the SteamCMD boundary.
      #
      # @param app [String]
      # @return [Hash{String => String}] branch name → current buildid
      sig { params(app: String).returns(T::Hash[String, String]) }
      def resolve_branches(app)
        SteamCmd.resolve_branches(app: app)
      end

      # Run the build through a steamcmd script: the login, then
      # `run_app_build`. The script holds the credentials, so it is created
      # with its mode and removed whatever happens.
      #
      # @param app_script [Pathname] the app build script
      # @param scratch [Pathname]
      # @return [String] the BuildID Steam assigned
      # @raise [UploadFailedError]
      # @raise [BuildIdNotReportedError]
      sig { params(app_script: Pathname, scratch: Pathname).returns(String) }
      def run_app_build(app_script, scratch)
        script = scratch / LOGIN_SCRIPT
        File.open(script, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(script_text(app_script)) }
        out, err, status = SteamCmd.run("+runscript", script.to_s)
        unless status.success?
          raise UploadFailedError, "steamcmd run_app_build #{app_script.basename} #{Lifecycle::Shell.describe(status)}: #{(err + out).strip.lines.last(5).join}"
        end

        out[BUILD_ID_PATTERN, 1] ||
          raise(BuildIdNotReportedError, "steamcmd finished #{app_script.basename} without reporting a BuildID:\n#{out.strip.lines.last(5).join}")
      ensure
        (scratch / LOGIN_SCRIPT).then { |script| script.delete if script.file? }
      end

      # The steamcmd script: fail fast rather than prompt, log in as the
      # build account, build, quit.
      #
      # @param app_script [Pathname]
      # @return [String]
      sig { params(app_script: Pathname).returns(String) }
      def script_text(app_script)
        <<~SCRIPT
          @ShutdownOnFailedCommand 1
          @NoPromptForPassword 1
          login #{login.join(" ")}
          run_app_build #{app_script}
          quit
        SCRIPT
      end

      # The `login` arguments: the build account, and its password when
      # one is stored or in the environment.
      #
      # @return [Array<String>]
      # @raise [Credentials::MissingCredentialError]
      sig { returns(T::Array[String]) }
      def login
        username = Credentials.resolve(
          namespace: CREDENTIAL_NAMESPACE, key: "username", env_var: "STEAM_USERNAME",
          prompt_label: "Steam build account (a Steamworks user with Edit App Metadata)", create_url: BUILD_ACCOUNT_URL, ui: @ui,
        )
        password = ENV.fetch("STEAM_PASSWORD") { Credentials.load(CREDENTIAL_NAMESPACE, "password") }
        [username, password].compact
      end

      # @param build_id [String]
      # @param options [SteamChannelOptions]
      # @param branch [String]
      # @param depots [Array<Integer>]
      # @return [String]
      sig { params(build_id: String, options: SteamChannelOptions, branch: String, depots: T::Array[Integer]).returns(String) }
      def summary(build_id, options, branch, depots)
        head = "steam build #{build_id} of app #{options.app} (depots #{depots.join(", ")})"
        if options.default_branch?(branch)
          "#{head} uploaded — set it live on the #{branch} branch in Steamworks: https://partner.steamgames.com/apps/builds/#{options.app}"
        else
          "#{head} set live on #{branch}"
        end
      end
    end
  end
end
