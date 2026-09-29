# typed: strict
# frozen_string_literal: true

require "stringio"
require_relative "settings"

module Dev
  # CLI accessor over Dev::Settings, surfaced as `dev config` — the
  # tool-guided way to manage the user settings file (no hand-written
  # YAML). Mirrors Dev::CredentialAccessor's shape: a global command whose
  # clean failures raise and are mapped to exit 1 at the dispatch boundary.
  #
  # One public method per verb; the `config` group in the command tree
  # routes `list` / `get` / `set` to them. Known-keys only: the registry is
  # Settings::KNOWN_KEYS, so the command and the resolver can never
  # disagree about what exists. `list` doubles
  # as the settings debugging tool — every key with its resolved value and
  # the layer it came from, gitconfig `--show-origin` style.
  class ConfigAccessor
    extend T::Sig

    class UsageError < RuntimeError; end

    # Raised for a key outside Settings::KNOWN_KEYS; the message lists the
    # valid ones.
    class UnknownKeyError < RuntimeError; end

    # Raised by `get` when the key resolves unset across all layers — the
    # CLI boundary maps it to a non-zero exit.
    class UnsetKeyError < RuntimeError; end

    USAGE = T.let("usage: dev config list | get <key> | set <key> <value>", String)

    # @param settings [Dev::Settings]
    sig { params(settings: Dev::Settings).void }
    def initialize(settings: Dev::Settings.new)
      @settings = settings
    end

    # `dev config list`: every known key with its resolved value and source
    # layer.
    #
    # @param out [IO]
    # @return [void]
    sig { params(out: T.any(IO, StringIO)).void }
    def list(out: $stdout)
      width = T.must(Dev::Settings::KNOWN_KEYS.keys.map(&:length).max)
      Dev::Settings::KNOWN_KEYS.each_key do |key|
        value, source = @settings.lookup(key)
        rendered = (source == :unset) ? "(unset)" : "#{value}  (#{source})"
        out.puts "#{key.ljust(width)}  #{rendered}"
      end
    end

    # `dev config get <key>`: print the key's resolved value.
    #
    # @param args [Array<String>] argv after "get" — exactly one key
    # @param out [IO]
    # @return [void]
    # @raise [UsageError] without exactly one key
    # @raise [UnsetKeyError] when the key resolves unset
    sig { params(args: T::Array[String], out: T.any(IO, StringIO)).void }
    def get(args, out: $stdout)
      key, *extra = args
      raise UsageError, USAGE unless key && extra.empty?

      value, _source = @settings.lookup(validated(key))
      raise UnsetKeyError, "#{key} is unset" unless value

      out.puts value
    end

    # `dev config set <key> <value>`: write the key to the user config file.
    #
    # @param args [Array<String>] argv after "set" — exactly a key and a value
    # @param out [IO]
    # @return [void]
    # @raise [UsageError] without exactly a key and value
    sig { params(args: T::Array[String], out: T.any(IO, StringIO)).void }
    def set(args, out: $stdout)
      key, value, *extra = args
      raise UsageError, USAGE unless key && value && extra.empty?

      @settings.set(validated(key), value)
      out.puts "#{key} set in #{@settings.config_path}"
    end

    private

    # @param key [String]
    # @return [String] the key, when known
    # @raise [UnknownKeyError] otherwise
    sig { params(key: String).returns(String) }
    def validated(key)
      return key if Dev::Settings::KNOWN_KEYS.key?(key)

      raise UnknownKeyError,
        "unknown key #{key.inspect} — known keys: #{Dev::Settings::KNOWN_KEYS.keys.join(", ")}"
    end
  end
end
