# typed: strict
# frozen_string_literal: true

require "dev/environment_ref"
require "dev/lifecycle"

module Dev
  module Cli
    # Parses the dev.yml `targets:` mapping into Lifecycle::Target values —
    # the dev.yml boundary for the lifecycle vocabulary, as CommandParser is
    # for commands. Each entry's `desc`, `platforms`,
    # `configs` and `environment` are coerced here; the ids go through the
    # enums' parse, so an id outside dev's closed sets fails at load with
    # the set listed, and `environment` becomes references the composition
    # root binds against the lock (the parser stays lock-free, as
    # CommandParser does). The builder and packager keys become their
    # declarations: `build:` a script builder; `package:` a script packager,
    # or `packager:` one of dev's built-ins by name — `archive` (the default,
    # with its options as a mapping: `{ archive: { format: tar, split: 2GiB } }`),
    # `as-is`, `none`. The rules a single target owns (its name's shape and
    # suffix, duplicate axis values, a per-platform environment's fit with
    # its platforms) are Target's and surface from its constructor; the
    # rules that span targets and commands are ProjectManifestLoader's.
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

      # `environment:` that is neither a name nor a mapping of platform id →
      # name, or a mapping whose key is no platform id or whose value is no
      # name.
      class InvalidEnvironmentError < ArgumentError; end

      # `build:` that is not a non-empty command line, or a `builder:` key,
      # which no builder form takes.
      class InvalidBuilderError < ArgumentError; end

      # `package:` that is not a non-empty command line; `packager:` naming
      # no built-in, or carrying options that are not the built-in's.
      class InvalidPackagerError < ArgumentError; end

      # Both `package:` and `packager:` on one target: a target has one
      # packager.
      class ConflictingPackagerError < ArgumentError; end

      PLATFORMS_KEY = "platforms"
      CONFIGS_KEY = "configs"
      ENVIRONMENT_KEY = "environment"
      BUILD_KEY = "build"
      BUILDER_KEY = "builder"
      PACKAGE_KEY = "package"
      PACKAGER_KEY = "packager"
      ARCHIVE_NAME = "archive"
      AS_IS_NAME = "as-is"
      NONE_NAME = "none"
      ARCHIVE_FORMAT_KEY = "format"
      ARCHIVE_SPLIT_KEY = "split"
      ARCHIVE_OPTION_KEYS = T.let([ARCHIVE_FORMAT_KEY, ARCHIVE_SPLIT_KEY].freeze, T::Array[String])

      TargetHash = T.type_alias { T::Hash[String, T.untyped] }

      # Parse the whole `targets:` mapping; absent means none declared.
      #
      # @param raw [Object] the `targets` value as YAML delivered it
      # @return [Hash{String => Lifecycle::Target}] in declaration order
      # @raise [InvalidTargetsError]
      # @raise [InvalidTargetError]
      # @raise [InvalidAxisError]
      # @raise [InvalidBuilderError]
      # @raise [InvalidPackagerError]
      # @raise [ConflictingPackagerError]
      # @raise [InvalidEnvironmentError]
      # @raise [Lifecycle::Target::InvalidTargetNameError]
      # @raise [Lifecycle::Target::ReservedTargetSuffixError]
      # @raise [Lifecycle::Target::DuplicateAxisValueError]
      # @raise [Lifecycle::Target::EnvironmentPlatformsError]
      sig { params(raw: T.untyped).returns(T::Hash[String, Lifecycle::Target]) }
      def parse_all(raw)
        return {} if raw.nil?
        raise InvalidTargetsError, "'targets' must be a mapping of name to target" unless raw.is_a?(Hash)

        raw.to_h do |name, entry|
          name = name.to_s
          unless entry.is_a?(Hash)
            raise InvalidTargetError, "target '#{name}': expected a mapping (desc, platforms, configs, environment, build, package/packager)"
          end

          [name, parse(name, entry)]
        end
      end

      # Parse one target entry.
      #
      # @param name [String] the `targets:` key
      # @param target_hash [TargetHash] the entry
      # @return [Lifecycle::Target]
      # @raise [InvalidAxisError]
      # @raise [InvalidBuilderError]
      # @raise [InvalidPackagerError]
      # @raise [ConflictingPackagerError]
      # @raise [InvalidEnvironmentError]
      # @raise [Lifecycle::Target::InvalidTargetNameError]
      # @raise [Lifecycle::Target::ReservedTargetSuffixError]
      # @raise [Lifecycle::Target::DuplicateAxisValueError]
      # @raise [Lifecycle::Target::EnvironmentPlatformsError]
      sig { params(name: String, target_hash: TargetHash).returns(Lifecycle::Target) }
      def parse(name, target_hash)
        # Coerces NilClass, TrueClass and FalseClass to String, as CommandParser does.
        desc = target_hash["desc"].to_s
        Lifecycle::Target.new(
          name:,
          desc: desc.empty? ? "(no description)" : desc,
          platforms: axis_ids(name, PLATFORMS_KEY, target_hash[PLATFORMS_KEY]).map { |id| parse_platform(name, id) },
          configs: axis_ids(name, CONFIGS_KEY, target_hash[CONFIGS_KEY]).map { |id| parse_config(name, id) },
          builder: parse_builder(name, target_hash),
          packager: parse_packager(name, target_hash),
          environment: parse_environment(name, target_hash),
        )
      end

      private

      # The builder declaration: `build: <command>`, or none.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @return [Lifecycle::BuilderSpec, nil]
      # @raise [InvalidBuilderError]
      sig { params(name: String, target_hash: TargetHash).returns(T.nilable(Lifecycle::BuilderSpec)) }
      def parse_builder(name, target_hash)
        if target_hash.key?(BUILDER_KEY)
          raise InvalidBuilderError,
            "target '#{name}': `#{BUILDER_KEY}:` names an integration builder, which lands with d3mlabs/dev#433 — " \
              "declare a `#{BUILD_KEY}:` script until then"
        end
        return nil unless target_hash.key?(BUILD_KEY)

        Lifecycle::BuilderSpec::Script.new(command: command_line(name, BUILD_KEY, target_hash[BUILD_KEY], InvalidBuilderError))
      end

      # The packager declaration: `package: <command>`, `packager: <name>`
      # or `packager: { <name>: { options } }`; dev's `archive` when neither.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @return [Lifecycle::PackagerSpec]
      # @raise [InvalidPackagerError]
      # @raise [ConflictingPackagerError]
      sig { params(name: String, target_hash: TargetHash).returns(Lifecycle::PackagerSpec) }
      def parse_packager(name, target_hash)
        if target_hash.key?(PACKAGE_KEY) && target_hash.key?(PACKAGER_KEY)
          raise ConflictingPackagerError,
            "target '#{name}': declares both `#{PACKAGE_KEY}:` and `#{PACKAGER_KEY}:` — a target has one packager; keep the script or the built-in"
        end
        if target_hash.key?(PACKAGE_KEY)
          return Lifecycle::PackagerSpec::Script.new(
            command: command_line(name, PACKAGE_KEY, target_hash[PACKAGE_KEY], InvalidPackagerError),
          )
        end
        return Lifecycle::PackagerSpec::Archive.new unless target_hash.key?(PACKAGER_KEY)

        builtin_packager(name, target_hash[PACKAGER_KEY])
      end

      # @param name [String] the target, for messages
      # @param raw [Object] the `packager:` value: a built-in's name, or a
      #   one-key mapping of a built-in's name to its options
      # @return [Lifecycle::PackagerSpec]
      # @raise [InvalidPackagerError]
      sig { params(name: String, raw: T.untyped).returns(Lifecycle::PackagerSpec) }
      def builtin_packager(name, raw)
        packager_name, options = case raw
        when String then [raw, {}]
        when Hash
          unless raw.size == 1 && raw.values.first.is_a?(Hash)
            raise InvalidPackagerError,
              "target '#{name}': `#{PACKAGER_KEY}:` as a mapping is one built-in's name to its options " \
                "(`{ #{ARCHIVE_NAME}: { #{ARCHIVE_FORMAT_KEY}: tar, #{ARCHIVE_SPLIT_KEY}: 2GiB } }`), got #{raw.inspect}"
          end

          [raw.keys.first.to_s, raw.values.first]
        else
          raise InvalidPackagerError, "target '#{name}': `#{PACKAGER_KEY}:` must be a built-in's name or a mapping, got #{raw.inspect}"
        end

        case packager_name
        when ARCHIVE_NAME then Lifecycle::PackagerSpec::Archive.new(form: archive_form(name, options))
        when AS_IS_NAME then optionless(name, AS_IS_NAME, options, Lifecycle::PackagerSpec::AsIs.new)
        when NONE_NAME then optionless(name, NONE_NAME, options, Lifecycle::PackagerSpec::None.new)
        else
          raise InvalidPackagerError,
            "target '#{name}': unknown packager #{packager_name.inspect} (built-ins: #{Lifecycle::PackagerSpec::BUILTIN_NAMES.join(", ")})"
        end
      end

      # The `environment:` value as declared — one reference, or one per
      # platform id — unresolved: the lock is the composition root's to
      # consult. Whether a per-platform mapping fits the target's platforms
      # is Target's to say; here each key is only required to be an id.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @return [Lifecycle::TargetEnvironment, nil] nil when absent
      # @raise [InvalidEnvironmentError]
      sig { params(name: String, target_hash: TargetHash).returns(T.nilable(Lifecycle::TargetEnvironment)) }
      def parse_environment(name, target_hash)
        return nil unless target_hash.key?(ENVIRONMENT_KEY)

        raw = target_hash[ENVIRONMENT_KEY]
        case raw
        when Hash
          references = raw.to_h do |platform_id, value|
            [parse_environment_platform(name, platform_id.to_s), parse_environment_reference(name, value)]
          end
          Lifecycle::TargetEnvironment::PerPlatform.new(references:)
        else
          Lifecycle::TargetEnvironment::Single.new(reference: parse_environment_reference(name, raw))
        end
      end

      # @param name [String] the target, for messages
      # @param options [Hash] the `archive:` options: `format`, `split`
      # @return [Lifecycle::Archive::Form]
      # @raise [InvalidPackagerError]
      sig { params(name: String, options: T::Hash[T.untyped, T.untyped]).returns(Lifecycle::Archive::Form) }
      def archive_form(name, options)
        unknown = options.keys.map(&:to_s) - ARCHIVE_OPTION_KEYS
        unless unknown.empty?
          raise InvalidPackagerError,
            "target '#{name}': #{ARCHIVE_NAME} takes #{ARCHIVE_OPTION_KEYS.join(", ")}, not #{unknown.join(", ")}"
        end

        split = options[ARCHIVE_SPLIT_KEY]
        format = options[ARCHIVE_FORMAT_KEY]
        # `split:` alone means the tar form: zip has none, and the plan's own
        # example (`{ archive: { split: 2GiB } }`) writes it that way.
        format = Lifecycle::Archive::Format::Tar.serialize if format.nil? && !split.nil?
        Lifecycle::Archive::Form.for(
          format: format.nil? ? Lifecycle::Archive::Format::Zip : Lifecycle::Archive::Format.parse(format.to_s),
          split: split.nil? ? nil : Lifecycle::ByteSize.parse(split.to_s),
        )
      rescue Lifecycle::Archive::UnknownFormatError, Lifecycle::ByteSize::InvalidByteSizeError,
             Lifecycle::Archive::SplitNeedsTarError => e
        raise InvalidPackagerError, "target '#{name}': #{ARCHIVE_NAME}: #{e.message}"
      end

      # @param name [String] the target, for messages
      # @param packager_name [String]
      # @param options [Hash] must be empty
      # @param spec [Lifecycle::PackagerSpec] the declaration when it is
      # @return [Lifecycle::PackagerSpec]
      # @raise [InvalidPackagerError]
      sig do
        params(name: String, packager_name: String, options: T::Hash[T.untyped, T.untyped], spec: Lifecycle::PackagerSpec)
          .returns(Lifecycle::PackagerSpec)
      end
      def optionless(name, packager_name, options, spec)
        return spec if options.empty?

        raise InvalidPackagerError, "target '#{name}': #{packager_name} takes no options, got #{options.keys.join(", ")}"
      end

      # A `build:`/`package:` value: a non-empty string.
      #
      # @param name [String] the target, for messages
      # @param key [String] BUILD_KEY or PACKAGE_KEY
      # @param raw [Object]
      # @param error_class [Class] InvalidBuilderError or InvalidPackagerError
      # @return [String]
      sig { params(name: String, key: String, raw: T.untyped, error_class: T.class_of(ArgumentError)).returns(String) }
      def command_line(name, key, raw, error_class)
        return raw if raw.is_a?(String) && !raw.strip.empty?

        raise error_class, "target '#{name}': `#{key}:` must be a command line, got #{raw.inspect}"
      end

      # @param name [String] the target, for messages
      # @param raw [Object] one `environment:` value, or one of a mapping's values
      # @return [EnvironmentRef]
      # @raise [InvalidEnvironmentError]
      sig { params(name: String, raw: T.untyped).returns(EnvironmentRef) }
      def parse_environment_reference(name, raw)
        unless raw.is_a?(String) && !raw.empty?
          raise InvalidEnvironmentError,
            "target '#{name}': '#{ENVIRONMENT_KEY}' must name an image block or be '#{EnvironmentRef::HOST}' — " \
              "one value, or one per platform (`{ linux64: <name>, macos: #{EnvironmentRef::HOST} }`) — got #{raw.inspect}"
        end
        EnvironmentRef.parse(raw)
      end

      # @param name [String] the target, for messages
      # @param id [String] a key of the per-platform mapping
      # @return [Lifecycle::Platform]
      # @raise [InvalidEnvironmentError] naming the target and listing the set
      sig { params(name: String, id: String).returns(Lifecycle::Platform) }
      def parse_environment_platform(name, id)
        Lifecycle::Platform.parse(id)
      rescue Lifecycle::UnknownPlatformError => e
        raise InvalidEnvironmentError, "target '#{name}': '#{ENVIRONMENT_KEY}': #{e.message}"
      end

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
end
