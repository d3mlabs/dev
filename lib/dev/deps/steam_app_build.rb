# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "vdf"

module Dev
  module Deps
    # One Steam app build as the content builder takes it (dev#192 K5,
    # dev#426): the **app build script** (`app_build_<app>.vdf` — AppID,
    # Desc, BuildOutput, SetLive, and the depots it builds) referencing one
    # **depot build script** per depot (`depot_build_<depot>.vdf` — DepotID
    # and a ContentRoot mapped whole into the depot's root). What
    # `steamcmd +run_app_build` reads; Steam chunks each content root,
    # uploads the delta against the depot's previous build and assigns the
    # whole a BuildID.
    #
    # Two of its inputs are the destination's and the track's rather than
    # any build's — the depot ids (SteamChannelOptions) and the branch —
    # which is why this is written at deploy time in the channel's scratch
    # and never baked into an artifact (K0). `set_live` is the beta branch
    # to set live after the upload, or nil to upload only: Steam refuses to
    # set the default branch live from a script, so a live-track deploy
    # leaves that last step to the operator and the receipt says so.
    class SteamAppBuild < T::Struct
      extend T::Sig

      SCRIPTS_DIR = "scripts"

      # @return [Integer] the AppID
      const :app, Integer
      # @return [String] what Steamworks' "Your Builds" page shows for the build
      const :desc, String
      # @return [Hash{Integer => Pathname}] DepotID → its content root, an
      #   existing directory holding exactly the depot's files
      const :depots, T::Hash[Integer, Pathname]
      # @return [Pathname] where steamcmd keeps its logs, manifests and
      #   chunk cache between builds; the delta is computed against it
      const :build_output, Pathname
      # @return [String, nil] the branch to set live, or nil for none
      const :set_live, T.nilable(String), default: nil

      # Write the scripts under `dir/scripts/`.
      #
      # @param dir [Pathname] the channel's scratch
      # @return [Pathname] the app build script, what `run_app_build` takes
      sig { params(dir: Pathname).returns(Pathname) }
      def write(dir)
        scripts = dir / SCRIPTS_DIR
        scripts.mkpath
        build_output.mkpath
        depot_scripts = depots.to_h do |depot, content_root|
          script = scripts / "depot_build_#{depot}.vdf"
          script.write(depot_script(depot, content_root))
          [depot.to_s, script.basename.to_s]
        end
        app_script = scripts / "app_build_#{app}.vdf"
        app_script.write(app_script_text(depot_scripts))
        app_script
      end

      private

      # @param depot_scripts [Hash{String => String}] DepotID → its script's
      #   file name, relative to the app script as Steam resolves it
      # @return [String]
      sig { params(depot_scripts: T::Hash[String, String]).returns(String) }
      def app_script_text(depot_scripts)
        block = {
          "AppID" => app,
          "Desc" => desc,
          "BuildOutput" => build_output.to_s,
          # A depot script's own ContentRoot is absolute, so the app's is
          # unused — but the key is required, and the scripts directory is
          # a root that holds no content to upload by mistake.
          "ContentRoot" => ".",
          "SetLive" => set_live.to_s,
          "Depots" => depot_scripts,
        }
        Vdf.dump("AppBuild", block)
      end

      # @param depot [Integer]
      # @param content_root [Pathname]
      # @return [String]
      sig { params(depot: Integer, content_root: Pathname).returns(String) }
      def depot_script(depot, content_root)
        block = {
          "DepotID" => depot,
          "ContentRoot" => content_root.to_s,
          "FileMapping" => { "LocalPath" => "*", "DepotPath" => ".", "Recursive" => "1" },
        }
        Vdf.dump("DepotBuild", block)
      end
    end
  end
end
