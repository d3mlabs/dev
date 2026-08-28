# frozen_string_literal: true

require_relative "settings"

module Dev
  # CLI accessor over Dev::Settings, surfaced as `dev config` — the
  # tool-guided way to manage the user settings file (no hand-written
  # YAML). Mirrors Dev::CredentialAccessor's shape: a global command whose
  # clean failures raise and are mapped to exit 1 at the dispatch boundary.
  #
  # Known-keys only: the registry is Settings::KNOWN_KEYS, so the command
  # and the resolver can never disagree about what exists. `list` doubles
  # as the settings debugging tool — every key with its resolved value and
  # the layer it came from, gitconfig `--show-origin` style.
  class ConfigAccessor
    class UsageError < RuntimeError; end

    # Raised for a key outside Settings::KNOWN_KEYS; the message lists the
    # valid ones.
    class UnknownKeyError < RuntimeError; end

    # Raised by `get` when the key resolves unset across all layers — the
    # CLI boundary maps it to a non-zero exit.
    class UnsetKeyError < RuntimeError; end

    USAGE = "usage: dev config list | get <key> | set <key> <value>"

    # @param settings [Dev::Settings]
    def initialize(settings: Dev::Settings.new)
      @settings = settings
    end

    # Dispatch a `dev config …` invocation.
    #
    # @param args [Array<String>] argv after the "config" command
    # @param out  [IO] output stream
    # @raise [UsageError] on an unrecognized invocation
    def run(args, out: $stdout)
      subcommand, *rest = args
      case subcommand
      when "list" then list(out)
      when "get" then get(out, *rest)
      when "set" then set(out, *rest)
      else raise UsageError, USAGE
      end
    end

    private

    # Every known key with its resolved value and source layer.
    #
    # @param out [IO]
    # @return [void]
    def list(out)
      width = Dev::Settings::KNOWN_KEYS.keys.map(&:length).max
      Dev::Settings::KNOWN_KEYS.each_key do |key|
        value, source = @settings.lookup(key)
        rendered = (source == :unset) ? "(unset)" : "#{value}  (#{source})"
        out.puts "#{key.ljust(width)}  #{rendered}"
      end
    end

    # @param out [IO]
    # @param key [String, nil]
    # @return [void]
    # @raise [UsageError] without a key
    # @raise [UnsetKeyError] when the key resolves unset
    def get(out, key = nil, *extra)
      raise UsageError, USAGE unless key && extra.empty?

      value, _source = @settings.lookup(validated(key))
      raise UnsetKeyError, "#{key} is unset" unless value

      out.puts value
    end

    # @param out [IO]
    # @param key [String, nil]
    # @param value [String, nil]
    # @return [void]
    # @raise [UsageError] without a key and value
    def set(out, key = nil, value = nil, *extra)
      raise UsageError, USAGE unless key && value && extra.empty?

      @settings.set(validated(key), value)
      out.puts "#{key} set in #{@settings.config_path}"
    end

    # @param key [String]
    # @return [String] the key, when known
    # @raise [UnknownKeyError] otherwise
    def validated(key)
      return key if Dev::Settings::KNOWN_KEYS.key?(key)

      raise UnknownKeyError,
        "unknown key #{key.inspect} — known keys: #{Dev::Settings::KNOWN_KEYS.keys.join(", ")}"
    end
  end
end
