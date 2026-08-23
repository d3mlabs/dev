# frozen_string_literal: true

require "yaml"

module Dev
  # Global (per-machine) settings — the seam where an org's identity enters
  # a generic dev install (dev is public and hardcodes no org content).
  # Per-key resolution is layered, gitconfig-style:
  #
  #   1. ENV var (DEV_PLANS_REPO, DEV_KNOWLEDGE_REPO, DEV_BASELINE_REPO) —
  #      CI/fleet management, no files needed
  #   2. user file: ~/.config/dev/config.yml (or $XDG_CONFIG_HOME/dev/…) —
  #      individuals and per-user overrides
  #   3. system file: $(brew --prefix)/etc/dev/config.yml — shipped by an
  #      org's deployment formula (see README "Deploying dev to an org")
  #
  # Keys:
  #
  #   plans_repo: d3mlabs/plans
  #   knowledge_repo: d3mlabs/knowledge
  #   baseline_repo: d3mlabs/knowledge
  #
  # `plans_repo` is the org-wide plans repo that `dev plan new --org` /
  # `dev plan link --org` target. `knowledge_repo` is the org knowledge repo
  # dev keeps a machine-local cache of. `baseline_repo` is the repo whose
  # `baseline/dependencies.rb` declares the host baseline `dev up`
  # converges. Leaving a nilable key unset turns its feature off.
  class Settings
    class MissingSettingError < RuntimeError; end

    # @return [String] path of the user config file (layer 2)
    attr_reader :config_path

    # @param config_path [String, nil] user file override for tests;
    #   defaults to the XDG config location
    # @param system_config_path [String, nil] system file override for
    #   tests; defaults to the Homebrew prefix's etc/dev/config.yml
    def initialize(config_path: nil, system_config_path: nil)
      @config_path = config_path || default_config_path
      @system_config_path = system_config_path || default_system_config_path
    end

    # @return [String] "owner/repo" of the org-wide plans repo
    # @raise [MissingSettingError] when unset in every layer
    def plans_repo
      setting("plans_repo", "DEV_PLANS_REPO") ||
        raise(MissingSettingError,
          "no org plans repo configured — add `plans_repo: <owner>/<repo>` " \
          "to #{@config_path} (or set DEV_PLANS_REPO).")
    end

    # The org knowledge repo the machine cache syncs from. Unset is a
    # supported state, not an error: machines without the setting have no
    # org learnings sync.
    #
    # @return [String, nil] "owner/repo" (or any git-clonable URL), or nil
    def knowledge_repo
      setting("knowledge_repo", "DEV_KNOWLEDGE_REPO")
    end

    # The repo whose baseline/dependencies.rb declares the host baseline.
    # Unset is a supported state: no baseline to converge, no drift nag —
    # dev stays generic.
    #
    # @return [String, nil] "owner/repo", or nil
    def baseline_repo
      setting("baseline_repo", "DEV_BASELINE_REPO")
    end

    private

    # Resolve one key through the layers: ENV → user file → system file.
    # Empty strings count as unset at every layer.
    #
    # @param key [String] config file key
    # @param env_var [String] ENV override name
    # @return [String, nil]
    def setting(key, env_var)
      from_env = ENV[env_var]
      return from_env if from_env && !from_env.empty?

      value = layered_config[key]
      (value && !value.empty?) ? value : nil
    end

    # @return [String]
    def default_config_path
      config_home = ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
      File.join(config_home, "dev", "config.yml")
    end

    # The system layer an org deployment formula installs into the Homebrew
    # prefix (pkgetc). Prefix from HOMEBREW_PREFIX when set, else the first
    # standard install location present on this machine; nil (an empty
    # layer) on brewless machines.
    #
    # @return [String, nil]
    def default_system_config_path
      prefix = ENV["HOMEBREW_PREFIX"]
      prefix = nil if prefix && prefix.empty?
      prefix ||= ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"].find { |p| Dir.exist?(p) }
      prefix && File.join(prefix, "etc", "dev", "config.yml")
    end

    # @return [Hash] user keys merged over system keys; missing files are
    #   empty layers
    def layered_config
      load_yaml(@system_config_path).merge(load_yaml(@config_path))
    end

    # @param path [String, nil]
    # @return [Hash]
    def load_yaml(path)
      return {} unless path && File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    end
  end
end
