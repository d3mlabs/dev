# typed: strict
# frozen_string_literal: true

require "fileutils"
require "yaml"

module Dev
  # Global (per-machine) settings — the seam where an org's identity enters
  # a generic dev install (dev is public and hardcodes no org content).
  # Per-key resolution is layered, gitconfig-style:
  #
  #   1. ENV var (DEV_PLANS_REPO, DEV_KNOWLEDGE_REPO,
  #      DEV_DEPLOYMENT_FORMULA) — CI/fleet management, no files needed
  #   2. user file: ~/.config/dev/config.yml (or $XDG_CONFIG_HOME/dev/…) —
  #      individuals and per-user overrides
  #   3. system file: $(brew --prefix)/etc/dev/config.yml — shipped by an
  #      org's deployment formula (see README "Org configuration & deployment")
  #
  # Keys:
  #
  #   plans_repo: d3mlabs/plans
  #   knowledge_repo: d3mlabs/knowledge
  #   deployment_formula: d3mlabs/d3mlabs/dev
  #
  # `plans_repo` is the org-wide plans repo that `dev plan new --org` /
  # `dev plan link --org` target. `knowledge_repo` is the org knowledge repo
  # dev keeps a machine-local cache of. `deployment_formula` is the brew
  # formula `dev up`'s self-update upgrades — the deployment names itself
  # (see Dev::HostService). Leaving a nilable key unset turns its
  # feature off.
  class Settings
    extend T::Sig

    class MissingSettingError < RuntimeError; end

    # The settings registry: every known key and its ENV override. The one
    # list `dev config` reads (never a duplicated copy that can drift) —
    # a new setting joins here and the command picks it up for free.
    KNOWN_KEYS = T.let(
      {
        "plans_repo" => "DEV_PLANS_REPO",
        "knowledge_repo" => "DEV_KNOWLEDGE_REPO",
        "deployment_formula" => "DEV_DEPLOYMENT_FORMULA",
        "container_engine" => "DEV_CONTAINER_ENGINE",
      }.freeze,
      T::Hash[String, String],
    )

    # @return [String] path of the user config file (layer 2)
    sig { returns(String) }
    attr_reader :config_path

    # The system layer's location (layer 3); nil on brewless machines. Its
    # directory is also where a deployment ships the org Brewfile, so the
    # host converge reads this to find both.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    attr_reader :system_config_path

    # @param config_path [String, nil] user file override for tests;
    #   defaults to the XDG config location
    # @param system_config_path [String, nil] system file override for
    #   tests; defaults to the Homebrew prefix's etc/dev/config.yml
    sig { params(config_path: T.nilable(String), system_config_path: T.nilable(String)).void }
    def initialize(config_path: nil, system_config_path: nil)
      @config_path = T.let(config_path || default_config_path, String)
      @system_config_path = T.let(system_config_path || default_system_config_path, T.nilable(String))
    end

    # @return [String] "owner/repo" of the org-wide plans repo
    # @raise [MissingSettingError] when unset in every layer
    sig { returns(String) }
    def plans_repo
      lookup("plans_repo").first ||
        raise(MissingSettingError,
          "no org plans repo configured — add `plans_repo: <owner>/<repo>` " \
          "to #{@config_path} (or set DEV_PLANS_REPO).")
    end

    # The org knowledge repo the machine cache syncs from. Unset is a
    # supported state, not an error: machines without the setting have no
    # org learnings sync.
    #
    # @return [String, nil] "owner/repo" (or any git-clonable URL), or nil
    sig { returns(T.nilable(String)) }
    def knowledge_repo
      lookup("knowledge_repo").first
    end

    # The brew formula the `dev up` self-update upgrades — the org
    # deployment's own name, shipped in the config.yml it installs. Unset is
    # a supported state: no deployment to self-update (tapless individuals
    # fall back to dev-core, source checkouts skip entirely).
    #
    # @return [String, nil] e.g. "d3mlabs/d3mlabs/dev", or nil
    sig { returns(T.nilable(String)) }
    def deployment_formula
      lookup("deployment_formula").first
    end

    # The per-user container engine record ("docker" or "colima"), written at
    # provisioning time (e.g. the agent user's colima, by `dev runner
    # register`'s bootstrap). Resolution reads the invoking user's own config,
    # so nothing crosses the sudo boundary. Unset is a supported state: the
    # bare-docker default (see Dev::ContainerEngine.resolve).
    #
    # @return [String, nil] engine name, or nil for the default
    sig { returns(T.nilable(String)) }
    def container_engine
      lookup("container_engine").first
    end

    # Resolve a known key together with the layer it came from: ENV → user
    # file → system file, empty strings counting as unset at every layer.
    # The one resolution path — the typed getters and the `dev config` view
    # (gitconfig --show-origin style) both read through here, so they can
    # never disagree.
    #
    # @param key [String] a KNOWN_KEYS key
    # @return [Array(String, Symbol), Array(nil, Symbol)] value and source
    #   layer: :env, :user, :system, or :unset (value nil)
    sig { params(key: String).returns([T.nilable(String), Symbol]) }
    def lookup(key)
      env_value = present(ENV[KNOWN_KEYS.fetch(key)])
      return [env_value, :env] if env_value

      user_value = present(load_yaml(@config_path)[key])
      return [user_value, :user] if user_value

      system_value = present(load_yaml(@system_config_path)[key])
      return [system_value, :system] if system_value

      [nil, :unset]
    end

    # Write a known key into the user file (layer 2), creating it if
    # missing and preserving its other keys. String-keyed, string-valued
    # dump only — the file stays hand-readable plain YAML.
    #
    # @param key [String] a KNOWN_KEYS key
    # @param value [String]
    # @return [void]
    sig { params(key: String, value: String).void }
    def set(key, value)
      KNOWN_KEYS.fetch(key)
      FileUtils.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, YAML.dump(load_yaml(@config_path).merge(key => value.to_s)))
    end

    private

    # @param value [String, nil]
    # @return [String, nil] the value, with empty strings counting as unset
    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def present(value)
      (value && !value.to_s.empty?) ? value.to_s : nil
    end

    # @return [String]
    sig { returns(String) }
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
    sig { returns(T.nilable(String)) }
    def default_system_config_path
      prefix = ENV["HOMEBREW_PREFIX"]
      prefix = nil if prefix && prefix.empty?
      prefix ||= ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"].find { |p| Dir.exist?(p) }
      prefix && File.join(prefix, "etc", "dev", "config.yml")
    end

    # @param path [String, nil]
    # @return [Hash]
    sig { params(path: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
    def load_yaml(path)
      return {} unless path && File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    end
  end
end
