# frozen_string_literal: true

require "open3"
require_relative "repository"
require_relative "dependency"

module Dev
  module Deps
    # Resolves the Cursor agent CLI to a pinned version.
    #
    # Cursor publishes no release feed; the served install script
    # (https://cursor.com/install) bakes the current version into its download
    # URL at serve time. Resolution fetches the script and extracts that baked
    # version — a single metadata-sized request, no artifact download — so the
    # lock pins exactly what the script would have installed at resolve time.
    #
    # Declared in dependencies.rb as:
    #   cursor_agent "cursor-agent", install_dir: "~/.dev/tools/cursor-agent"
    class CursorAgentRepository < Repository
      # curl could not fetch the install script (network down, endpoint gone).
      class InstallScriptFetchError < StandardError; end

      # The script no longer carries a recognizable baked download URL — the
      # served shape drifted and this repository needs updating.
      class VersionParseError < StandardError; end

      INSTALL_SCRIPT_URL = "https://cursor.com/install"

      # The baked version sits in the script's download URL:
      #   https://downloads.cursor.com/lab/<version>/${OS}/${ARCH}/...
      BAKED_URL_PATTERN = %r{downloads\.cursor\.com/lab/([^/"]+)/}

      # Resolve the agent CLI to the version the served script currently bakes.
      #
      # @param id [Hash] must include "name", "integration", "group",
      #   "install_dir"
      # @return [Dependency]
      # @raise [InstallScriptFetchError] if the script cannot be fetched
      # @raise [VersionParseError] if no baked version is found in it
      def fetch(id)
        script, ok = fetch_install_script
        unless ok
          raise InstallScriptFetchError,
            "could not fetch #{INSTALL_SCRIPT_URL} — is the network up?"
        end

        version = script[BAKED_URL_PATTERN, 1]
        unless version
          raise VersionParseError,
            "no baked download URL found in #{INSTALL_SCRIPT_URL} — " \
            "the served script's shape changed; update CursorAgentRepository"
        end

        Dependency.new(
          name: id["name"],
          integration: id["integration"].to_sym,
          group: id["group"].to_sym,
          version: version,
          hash: nil,
          metadata: { "install_dir" => id["install_dir"] },
        )
      end

      private

      # Fetch the served install script. Isolated so tests can stub the
      # network boundary.
      #
      # @return [Array(String, Boolean)] script body, success?
      def fetch_install_script
        out, _err, status = Open3.capture3("curl", "-fsSL", INSTALL_SCRIPT_URL)
        [out, status.success?]
      rescue Errno::ENOENT
        ["", false]
      end
    end
  end
end
