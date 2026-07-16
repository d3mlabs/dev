# frozen_string_literal: true

require "yaml"

module Dev
  module Plan
    # Global (per-machine) ai-flow settings, read from ~/.config/dev/config.yml
    # (or $XDG_CONFIG_HOME/dev/config.yml) — the same directory as dev's
    # credentials file. Currently one key:
    #
    #   plans_repo: d3mlabs/plans
    #
    # `plans_repo` is the org-wide plans repo that `dev plan new --org` /
    # `dev plan link --org` target. ENV override: DEV_PLANS_REPO (matching the
    # credentials ENV-first convention).
    class Settings
      class MissingSettingError < StandardError; end

      # @param config_path [String, nil] override for tests; defaults to the
      #   XDG config location
      def initialize(config_path: nil)
        @config_path = config_path || default_config_path
      end

      # @return [String] "owner/repo" of the org-wide plans repo
      # @raise [MissingSettingError] when unset
      def plans_repo
        from_env = ENV["DEV_PLANS_REPO"]
        return from_env if from_env && !from_env.empty?

        value = load_config["plans_repo"]
        return value if value && !value.empty?

        raise MissingSettingError,
              "no org plans repo configured — add `plans_repo: <owner>/<repo>` " \
              "to #{@config_path} (or set DEV_PLANS_REPO)."
      end

      private

      # @return [String]
      def default_config_path
        config_home = ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
        File.join(config_home, "dev", "config.yml")
      end

      # @return [Hash]
      def load_config
        return {} unless File.exist?(@config_path)

        YAML.safe_load(File.read(@config_path)) || {}
      end
    end
  end
end
