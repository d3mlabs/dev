# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"

module Dev
  # Parses the dev.yml `targets:` mapping into Lifecycle::Target values —
  # the dev.yml boundary for the lifecycle vocabulary, as CommandParser is
  # for commands (dev#192, K1). Each entry's `desc`, `platforms` and
  # `configs` are coerced here; the ids go through the enums' parse, so an
  # id outside dev's closed sets fails at load with the set listed. The
  # rules a single target owns (its name's shape and suffix, duplicate axis
  # values) are Target's and surface from its constructor; the rules that
  # span targets and commands are ProjectManifestLoader's.
  #
  # Stateless: reusable across manifests, inputs arrive as method arguments.
  class TargetParser
    extend T::Sig

    # `targets:` holding something other than a mapping of name → entry.
    class InvalidTargetsError < ArgumentError; end

    # A target entry that is not a mapping (a bare string, a list).
    class InvalidTargetError < ArgumentError; end

    # `platforms:` or `configs:` not a list of ids, or an id outside the set.
    class InvalidAxisError < ArgumentError; end

    PLATFORMS_KEY = "platforms"
    CONFIGS_KEY = "configs"

    TargetHash = T.type_alias { T::Hash[String, T.untyped] }

    # Parse the whole `targets:` mapping; absent means none declared.
    #
    # @param raw [Object] the `targets` value as YAML delivered it
    # @return [Hash{String => Lifecycle::Target}] in declaration order
    # @raise [InvalidTargetsError]
    # @raise [InvalidTargetError]
    # @raise [InvalidAxisError]
    # @raise [Lifecycle::Target::InvalidTargetNameError]
    # @raise [Lifecycle::Target::ReservedTargetSuffixError]
    # @raise [Lifecycle::Target::DuplicateAxisValueError]
    sig { params(raw: T.untyped).returns(T::Hash[String, Lifecycle::Target]) }
    def parse_all(raw)
      return {} if raw.nil?
      raise InvalidTargetsError, "'targets' must be a mapping of name to target" unless raw.is_a?(Hash)

      raw.to_h do |name, entry|
        name = name.to_s
        raise InvalidTargetError, "target '#{name}': expected a mapping (desc, platforms, configs)" unless entry.is_a?(Hash)

        [name, parse(name, entry)]
      end
    end

    # Parse one target entry.
    #
    # @param name [String] the `targets:` key
    # @param target_hash [TargetHash] the entry
    # @return [Lifecycle::Target]
    # @raise [InvalidAxisError]
    # @raise [Lifecycle::Target::InvalidTargetNameError]
    # @raise [Lifecycle::Target::ReservedTargetSuffixError]
    # @raise [Lifecycle::Target::DuplicateAxisValueError]
    sig { params(name: String, target_hash: TargetHash).returns(Lifecycle::Target) }
    def parse(name, target_hash)
      # Coerces NilClass, TrueClass and FalseClass to String, as CommandParser does.
      desc = target_hash["desc"].to_s
      Lifecycle::Target.new(
        name:,
        desc: desc.empty? ? "(no description)" : desc,
        platforms: axis_ids(name, PLATFORMS_KEY, target_hash[PLATFORMS_KEY]).map { |id| parse_platform(name, id) },
        configs: axis_ids(name, CONFIGS_KEY, target_hash[CONFIGS_KEY]).map { |id| parse_config(name, id) },
      )
    end

    private

    # The ids an axis lists; absent means the axis is not declared.
    #
    # @param name [String] the target, for messages
    # @param key [String] PLATFORMS_KEY or CONFIGS_KEY
    # @param raw [Object] the axis value as YAML delivered it
    # @return [Array<String>]
    # @raise [InvalidAxisError]
    sig { params(name: String, key: String, raw: T.untyped).returns(T::Array[String]) }
    def axis_ids(name, key, raw)
      return [] if raw.nil?
      return raw if raw.is_a?(Array) && raw.all?(String)

      raise InvalidAxisError, "target '#{name}': '#{key}' must be a list of ids, got #{raw.inspect}"
    end

    # @param name [String] the target, for messages
    # @param id [String]
    # @return [Lifecycle::Platform]
    # @raise [InvalidAxisError] naming the target and listing the set
    sig { params(name: String, id: String).returns(Lifecycle::Platform) }
    def parse_platform(name, id)
      Lifecycle::Platform.parse(id)
    rescue Lifecycle::UnknownPlatformError => e
      raise InvalidAxisError, "target '#{name}': #{PLATFORMS_KEY}: #{e.message}"
    end

    # @param name [String] the target, for messages
    # @param id [String]
    # @return [Lifecycle::Config]
    # @raise [InvalidAxisError] naming the target and listing the set
    sig { params(name: String, id: String).returns(Lifecycle::Config) }
    def parse_config(name, id)
      Lifecycle::Config.parse(id)
    rescue Lifecycle::UnknownConfigError => e
      raise InvalidAxisError, "target '#{name}': #{CONFIGS_KEY}: #{e.message}"
    end
  end
end
