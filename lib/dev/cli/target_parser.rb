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
    # CommandParser does). One key per port, named for the port —
    # `builder:` and `packager:` — and the value says how: a string is a
    # script (a command line run at the project root), a built-in's name or
    # a one-key mapping of that name to its options is the built-in. dev has
    # no built-in builder yet; its packagers are `archive` (the default,
    # `{ archive: { format: tar, split: 2GiB, files: [bin, lib], vendor:
    # true } }` with options), `as-is` and `none`. `build:` and `package:`
    # are the deprecated spellings of the two keys, read as them for one
    # release (ProjectManifestLoader notes each once per load); a target
    # spelling one port both ways is refused. The rules a single target
    # owns (its name's shape and suffix, duplicate axis values, a
    # per-platform environment's fit with its platforms) are Target's and
    # surface from its constructor; the rules that span targets and
    # commands are ProjectManifestLoader's.
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

      # `builder:` that is not a script's non-empty command line — a
      # mapping included, since dev has no built-in builder to name yet.
      class InvalidBuilderError < ArgumentError; end

      # `packager:` that is neither a script's non-empty command line nor a
      # built-in: a mapping naming no built-in, or carrying options that
      # are not the built-in's.
      class InvalidPackagerError < ArgumentError; end

      # One port declared under both its key and its deprecated spelling
      # (`builder:` beside `build:`, `packager:` beside `package:`): a
      # target has one builder and one packager.
      class ConflictingPortError < ArgumentError; end

      PLATFORMS_KEY = "platforms"
      CONFIGS_KEY = "configs"
      ENVIRONMENT_KEY = "environment"
      BUILDER_KEY = "builder"
      PACKAGER_KEY = "packager"
      # The deprecated spellings, read as the port keys for one release
      # (dev#692) and then removed.
      BUILD_KEY = "build"
      PACKAGE_KEY = "package"
      # Port key → its deprecated spelling; what the loader's note lists.
      DEPRECATED_PORT_KEYS = T.let(
        { BUILDER_KEY => BUILD_KEY, PACKAGER_KEY => PACKAGE_KEY }.freeze,
        T::Hash[String, String],
      )
      ARCHIVE_NAME = "archive"
      AS_IS_NAME = "as-is"
      NONE_NAME = "none"
      ARCHIVE_FORMAT_KEY = "format"
      ARCHIVE_SPLIT_KEY = "split"
      ARCHIVE_VENDOR_KEY = "vendor"
      ARCHIVE_FILES_KEY = "files"
      ARCHIVE_OPTION_KEYS = T.let(
        [ARCHIVE_FORMAT_KEY, ARCHIVE_SPLIT_KEY, ARCHIVE_VENDOR_KEY, ARCHIVE_FILES_KEY].freeze,
        T::Array[String],
      )

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
      # @raise [ConflictingPortError]
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
            raise InvalidTargetError, "target '#{name}': expected a mapping (desc, platforms, configs, environment, builder, packager)"
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
      # @raise [ConflictingPortError]
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

      # The builder declaration: `builder: <command>`, or none. A mapping is
      # the built-in form, and dev has no built-in builder to name yet.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @return [Lifecycle::BuilderSpec, nil]
      # @raise [InvalidBuilderError]
      # @raise [ConflictingPortError]
      sig { params(name: String, target_hash: TargetHash).returns(T.nilable(Lifecycle::BuilderSpec)) }
      def parse_builder(name, target_hash)
        key = declared_port_key(name, target_hash, BUILDER_KEY)
        return nil if key.nil?

        raw = target_hash[key]
        if raw.is_a?(Hash)
          raise InvalidBuilderError,
            "target '#{name}': `#{key}:` as a mapping names a built-in builder, and dev has none yet — " \
              "a builder is a script (`#{key}: ./bin/build`)"
        end

        Lifecycle::BuilderSpec::Script.new(command: command_line(name, key, raw, InvalidBuilderError))
      end

      # The packager declaration: `packager: <command>`, `packager: <name>`
      # or `packager: { <name>: { options } }`; dev's `archive` when absent.
      # A string naming a built-in is that built-in; any other string is a
      # script.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @return [Lifecycle::PackagerSpec]
      # @raise [InvalidPackagerError]
      # @raise [ConflictingPortError]
      sig { params(name: String, target_hash: TargetHash).returns(Lifecycle::PackagerSpec) }
      def parse_packager(name, target_hash)
        key = declared_port_key(name, target_hash, PACKAGER_KEY)
        return Lifecycle::PackagerSpec::Archive.new if key.nil?

        raw = target_hash[key]
        case raw
        when Hash then builtin_packager(name, key, raw)
        when String
          return builtin_packager(name, key, { raw => {} }) if Lifecycle::PackagerSpec::BUILTIN_NAMES.include?(raw)

          Lifecycle::PackagerSpec::Script.new(command: command_line(name, key, raw, InvalidPackagerError))
        else
          raise InvalidPackagerError,
            "target '#{name}': `#{key}:` is a script's command line, a built-in's name " \
              "(#{Lifecycle::PackagerSpec::BUILTIN_NAMES.join(", ")}) or a mapping of one built-in's name to its options, " \
              "got #{raw.inspect}"
        end
      end

      # The key one port is declared under — its own, or the deprecated
      # spelling the loader notes — or nil when the target leaves the port
      # undeclared. Both at once is refused: a target has one of each port.
      #
      # @param name [String] the target, for messages
      # @param target_hash [TargetHash]
      # @param key [String] BUILDER_KEY or PACKAGER_KEY
      # @return [String, nil] the key present in the entry
      # @raise [ConflictingPortError]
      sig { params(name: String, target_hash: TargetHash, key: String).returns(T.nilable(String)) }
      def declared_port_key(name, target_hash, key)
        deprecated_key = DEPRECATED_PORT_KEYS.fetch(key)
        declared = [key, deprecated_key].select { |candidate| target_hash.key?(candidate) }
        return declared.first unless declared.size == 2

        raise ConflictingPortError,
          "target '#{name}': declares both `#{deprecated_key}:` and `#{key}:` — a target has one #{key}; " \
            "`#{deprecated_key}:` is the deprecated spelling of `#{key}:`, so keep one"
      end

      # @param name [String] the target, for messages
      # @param key [String] the key the packager is declared under, for messages
      # @param raw [Hash] the built-in form: a one-key mapping of a
      #   built-in's name to its options
      # @return [Lifecycle::PackagerSpec]
      # @raise [InvalidPackagerError]
      sig { params(name: String, key: String, raw: T::Hash[T.untyped, T.untyped]).returns(Lifecycle::PackagerSpec) }
      def builtin_packager(name, key, raw)
        unless raw.size == 1 && raw.values.first.is_a?(Hash)
          raise InvalidPackagerError,
            "target '#{name}': `#{key}:` as a mapping is one built-in's name to its options " \
              "(`{ #{ARCHIVE_NAME}: { #{ARCHIVE_FORMAT_KEY}: tar, #{ARCHIVE_SPLIT_KEY}: 2GiB } }`), got #{raw.inspect}"
        end

        packager_name = raw.keys.first.to_s
        options = raw.values.first
        case packager_name
        when ARCHIVE_NAME
          Lifecycle::PackagerSpec::Archive.new(
            form: archive_form(name, options),
            files: archive_files(name, options),
            vendor: archive_vendor(name, options),
          )
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
      # @param options [Hash] the `archive:` options: `format`, `split`, `vendor`, `files`
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

      # The `vendor:` option: a YAML boolean, absent meaning false.
      #
      # @param name [String] the target, for messages
      # @param options [Hash] the `archive:` options
      # @return [Boolean]
      # @raise [InvalidPackagerError]
      sig { params(name: String, options: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
      def archive_vendor(name, options)
        vendor = options.fetch(ARCHIVE_VENDOR_KEY, false)
        return vendor if vendor == true || vendor == false

        raise InvalidPackagerError,
          "target '#{name}': #{ARCHIVE_NAME}: `#{ARCHIVE_VENDOR_KEY}:` is true or false, got #{vendor.inspect}"
      end

      # The `files:` option: a list of gitignore-syntax patterns, absent
      # meaning the whole install.
      #
      # @param name [String] the target, for messages
      # @param options [Hash] the `archive:` options
      # @return [Lifecycle::FileSelection]
      # @raise [InvalidPackagerError]
      sig { params(name: String, options: T::Hash[T.untyped, T.untyped]).returns(Lifecycle::FileSelection) }
      def archive_files(name, options)
        return Lifecycle::FileSelection.all unless options.key?(ARCHIVE_FILES_KEY)

        files = options[ARCHIVE_FILES_KEY]
        unless files.is_a?(Array) && !files.empty? && files.all?(String)
          raise InvalidPackagerError,
            "target '#{name}': #{ARCHIVE_NAME}: `#{ARCHIVE_FILES_KEY}:` is a list of patterns " \
              "(`[bin, lib, VERSION]`), got #{files.inspect}"
        end

        Lifecycle::FileSelection.parse(files)
      rescue Lifecycle::FilePattern::InvalidFilePatternError => e
        raise InvalidPackagerError, "target '#{name}': #{ARCHIVE_NAME}: `#{ARCHIVE_FILES_KEY}:` #{e.message}"
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

      # A port's script form: a non-empty string.
      #
      # @param name [String] the target, for messages
      # @param key [String] the key the port is declared under, for messages
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
