# typed: strict
# frozen_string_literal: true

require_relative "declarations"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"
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
    #   steam "SatisfactoryServer",
    #         app: 1690800,
    #         install_dir: "~/.dev/satisfactory-server"
    class SteamRepository < Repository
      extend T::Sig

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

      private

      # Isolated so tests can stub the SteamCMD boundary.
      #
      # @param app [String]
      # @return [Hash{String => String}] branch name → current buildid
      sig { params(app: String).returns(T::Hash[String, String]) }
      def resolve_branches(app)
        SteamCmd.resolve_branches(app: app)
      end
    end
  end
end
