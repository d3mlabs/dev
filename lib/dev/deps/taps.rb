# frozen_string_literal: true

module Dev
  module Deps
    # Registers Homebrew taps declared in Dev::Deps::Config.
    # file:// URLs are resolved relative to the given root directory.
    module Taps
      # Register all taps from the config.
      # root: project root directory; file:// URLs resolve relative to this.
      def self.register(root:)
        taps = Config.taps
        abort("No taps declared in dependencies.rb.") if taps.nil? || taps.empty?

        taps.each do |name, t|
          url = (t["url"] || "").to_s.strip
          if url.start_with?("file://")
            path = url.sub(/\Afile:\/\//, "")
            path = path.start_with?("./") ? File.join(root, path[2..]) : path
            path = File.expand_path(path)
            system("brew", "tap", name, path) || abort("brew tap #{name} #{path} failed")
          else
            system("brew", "tap", name) || abort("brew tap #{name} failed")
          end
        end

        setup_tap_env(root: root)
      end

      # Write TAP_NAME and LOCAL_TAP_DIR env vars for the first local tap.
      # Used by downstream steps (e.g. brew formula install that references a local tap).
      def self.setup_tap_env(root:)
        first_local = Config.local_tap_names.first
        return unless first_local

        url = (Config.taps[first_local]["url"] || "").to_s.strip
        path = url.sub(/\Afile:\/\//, "")
        path = path.start_with?("./") ? File.join(root, path[2..]) : path
        ENV["TAP_NAME"] = first_local
        ENV["LOCAL_TAP_DIR"] = File.expand_path(path)
      end
    end
  end
end
