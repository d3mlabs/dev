# frozen_string_literal: true

require "yaml"

module Dev
  # Global (per-machine) settings, read from ~/.config/dev/config.yml
  # (or $XDG_CONFIG_HOME/dev/config.yml) — the same directory as dev's
  # credentials file. Keys:
  #
  #   plans_repo: d3mlabs/plans
  #   knowledge_repo: d3mlabs/knowledge
  #   default_org: d3mlabs
  #
  # `plans_repo` is the org-wide plans repo that `dev plan new --org` /
  # `dev plan link --org` target. `knowledge_repo` is the org knowledge repo
  # dev keeps a machine-local cache of; leaving it unset simply means no org
  # learnings sync (dev is public and hardcodes no org content), and no
  # `default_org` means `dev clone` needs explicit <org>/<repo> targets.
  # ENV overrides: DEV_PLANS_REPO, DEV_KNOWLEDGE_REPO and DEV_DEFAULT_ORG
  # (matching the credentials ENV-first convention).
  class Settings
    class MissingSettingError < RuntimeError; end

    # @return [String] path of the config file settings are read from
    attr_reader :config_path

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

    # The org knowledge repo the machine cache syncs from. Unset is a
    # supported state, not an error: machines without the setting have no
    # org learnings sync.
    #
    # @return [String, nil] "owner/repo" (or any git-clonable URL), or nil
    def knowledge_repo
      from_env = ENV["DEV_KNOWLEDGE_REPO"]
      return from_env if from_env && !from_env.empty?

      value = load_config["knowledge_repo"]
      (value && !value.empty?) ? value : nil
    end

    # The GitHub org a bare `dev clone <repo>` expands under. Unset is a
    # supported state: bare targets then require an explicit <org>/<repo> —
    # dev is public and hardcodes no org.
    #
    # @return [String, nil] the org name, or nil
    def default_org
      from_env = ENV["DEV_DEFAULT_ORG"]
      return from_env if from_env && !from_env.empty?

      value = load_config["default_org"]
      (value && !value.empty?) ? value : nil
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
