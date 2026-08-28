# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    module Hooks
      # Post-install hook for brew "wwise-cli" that downloads the Wwise SDK.
      #
      # Usage in dependencies.rb:
      #   brew "wwise-cli", tap: "d3mlabs/d3mlabs",
      #        post_install: Dev::Deps::Hooks::WwiseDownload.new(
      #          version: "2023.1.14.8770",
      #          packages: ["SDK", "Authoring"],
      #          platforms: ["Windows_vc160", "Windows_vc170", "Linux"],
      #        )
      class WwiseDownload
        extend T::Sig

        class MissingVersionError < StandardError; end

        # @param version   [String]        SDK version (e.g. "2023.1.14.8770")
        # @param packages  [Array<String>] Wwise packages (e.g. ["SDK", "Authoring"])
        # @param platforms [Array<String>] deployment platforms (e.g. ["Windows_vc160", "Linux"])
        sig { params(version: String, packages: T::Array[String], platforms: T::Array[String]).void }
        def initialize(version:, packages: [], platforms: [])
          @version = version
          @packages = packages
          @platforms = platforms
        end

        # @param _name [String] brew entry name (e.g. "wwise-cli")
        # @param _opts [Hash]   brew entry options (unused — config is on the instance)
        sig { params(_name: String, _opts: T::Hash[T.untyped, T.untyped]).void }
        def call(_name, _opts)
          argv = T.let(["wwise-cli", "download", "--sdk-version", @version], T::Array[String])
          @packages.each { |pkg| argv += ["--filter", "Packages=#{pkg}"] }
          @platforms.each { |plat| argv += ["--filter", "DeploymentPlatforms=#{plat}"] }

          system(*T.unsafe(argv)) || abort("wwise-cli download failed for SDK #{@version}")
        end
      end
    end
  end
end
