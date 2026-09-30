# typed: strict
# frozen_string_literal: true

require "fileutils"
require "json"

module Dev
  # Points the Homebrew `docker` CLI at Homebrew's CLI plugins so `docker
  # buildx` (and therefore `docker build` with --secret / --build-context)
  # works without Docker Desktop.
  #
  # Docker Desktop ships the CLI plugins in ~/.docker/cli-plugins itself;
  # brew's `docker-buildx` formula instead drops them under
  # $(brew --prefix)/lib/docker/cli-plugins and documents a one-line
  # `cliPluginsExtraDirs` entry in ~/.docker/config.json as the way to
  # register them. This class owns that one line: it merges into whatever
  # config.json already holds (auths, contexts, the user's own dirs) and
  # never rewrites a file it cannot parse.
  class DockerCliPlugins
    extend T::Sig

    # ~/.docker/config.json exists but is not JSON — dev will not clobber a
    # file it cannot read back; the user fixes or removes it.
    class UnreadableConfigError < RuntimeError; end

    # Where brew's docker-* formulas link their CLI plugins, under the prefix.
    PLUGIN_DIR = "lib/docker/cli-plugins"
    KEY = "cliPluginsExtraDirs"

    # @param config_path [String] the docker CLI config file (~/.docker/config.json)
    # @param brew_prefix [String] the Homebrew prefix the plugins live under
    sig { params(config_path: String, brew_prefix: String).void }
    def initialize(config_path: File.join(Dir.home, ".docker", "config.json"), brew_prefix: self.class.default_brew_prefix)
      @config_path = config_path
      @brew_prefix = brew_prefix
    end

    # Ensure the brew plugin dir is listed in cliPluginsExtraDirs.
    #
    # @return [Symbol] :added when the entry was written, :already_present otherwise
    # @raise [UnreadableConfigError] when an existing config.json is not JSON
    sig { returns(Symbol) }
    def ensure!
      plugin_dir = File.join(@brew_prefix, PLUGIN_DIR)
      config = read_config
      dirs = Array(config[KEY])
      return :already_present if dirs.include?(plugin_dir)

      config[KEY] = dirs + [plugin_dir]
      FileUtils.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, "#{JSON.pretty_generate(config)}\n")
      :added
    end

    class << self
      extend T::Sig

      # The Homebrew prefix: the shellenv export when present, else the
      # platform default (Apple silicon vs Intel).
      #
      # @return [String]
      sig { returns(String) }
      def default_brew_prefix
        ENV.fetch("HOMEBREW_PREFIX") { RUBY_PLATFORM.include?("arm64") ? "/opt/homebrew" : "/usr/local" }
      end
    end

    private

    # @return [Hash] the parsed config, {} when the file does not exist
    # @raise [UnreadableConfigError]
    sig { returns(T::Hash[String, T.untyped]) }
    def read_config
      return {} unless File.exist?(@config_path)

      parsed = JSON.parse(File.read(@config_path))
      raise UnreadableConfigError, "#{@config_path} is not a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise UnreadableConfigError, "#{@config_path} is not valid JSON (#{e.message.lines.first&.strip}); fix or remove it"
    end
  end
end
