# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require "time"
require "dev/version"
require_relative "build"
require_relative "build_id"
require_relative "git_state"
require_relative "target"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The manifest of a lifecycle node, one variant per kind: an artifact
    # (`build-id.json`, beside the archive in the store) and a release
    # (`release.json`, an asset of the GitHub release). A deploy produces no
    # node; its record is a GitHub Deployment.
    #
    # The variants share a Stamp (when, by which dev, under which schema)
    # and each owns its `current?` rule. Sealed, so a reader matching on the
    # variant has a T.absurd proof.
    #
    # The files are string-keyed JSON. A build is written as its
    # fully-qualified name and read back through the grammar, which is why
    # reading needs the project's targets.
    module Manifest
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # No manifest file where one was asked for.
      class MissingManifestError < RuntimeError; end

      # A file that cannot be read as this kind of manifest: bad JSON, a
      # missing key, a value outside the vocabulary, a build the project no
      # longer declares.
      class MalformedManifestError < RuntimeError; end

      # The on-disk shape's version; bumped when a reader of today's shape
      # could not read tomorrow's.
      SCHEMA = 1
      INSTANT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

      JsonHash = T.type_alias { T::Hash[String, T.untyped] }

      # What every manifest records about its own writing: the schema it
      # follows, the dev that wrote it, and when.
      class Stamp < T::Struct
        extend T::Sig

        const :schema, Integer
        const :dev_version, String
        const :written_at, Time

        class << self
          extend T::Sig

          # A stamp for a manifest written now, by this dev.
          #
          # @param dev_version [String] (injectable for tests)
          # @param now [Time] (injectable for tests)
          # @return [Stamp]
          sig { params(dev_version: String, now: Time).returns(Stamp) }
          def now(dev_version: Dev::Version.current, now: Time.now)
            new(schema: SCHEMA, dev_version:, written_at: now.utc)
          end

          # @param hash [Hash] the `stamp` object of a manifest
          # @return [Stamp]
          # @raise [KeyError, TypeError, ArgumentError] on a malformed shape —
          #   the enclosing manifest's reader maps them
          sig { params(hash: JsonHash).returns(Stamp) }
          def from_json_hash(hash)
            new(
              schema: Integer(hash.fetch("schema")),
              dev_version: hash.fetch("dev_version").to_s,
              written_at: Time.iso8601(hash.fetch("written_at").to_s),
            )
          end
        end

        # @return [Hash] the JSON shape
        sig { returns(JsonHash) }
        def to_json_hash
          { "schema" => schema, "dev_version" => dev_version, "written_at" => written_at.utc.strftime(INSTANT_FORMAT) }
        end
      end

      sig { abstract.returns(Stamp) }
      def stamp; end

      # The file this kind of manifest is written to, inside its node's
      # directory.
      sig { abstract.returns(String) }
      def file_name; end

      # Whether the node this manifest describes is up to date with respect
      # to a working tree.
      #
      # @param state [GitState] the tree as it is now
      # @return [Boolean]
      sig { abstract.params(state: GitState).returns(T::Boolean) }
      def current?(state); end

      # @return [Hash] the JSON shape
      sig { abstract.returns(JsonHash) }
      def to_json_hash; end

      # Write the manifest into its node's directory (which must exist).
      #
      # @param dir [Pathname]
      # @return [void]
      sig { params(dir: Pathname).void }
      def write(dir)
        (dir / file_name).write("#{JSON.pretty_generate(to_json_hash)}\n")
      end

      class << self
        extend T::Sig

        # Read and parse one manifest file, mapping every way the file can
        # fail to read to the manifest errors.
        #
        # @param path [Pathname] the file
        # @yieldparam hash [Hash] the parsed document
        # @yieldreturn [Manifest] the variant
        # @return [Manifest]
        # @raise [MissingManifestError]
        # @raise [MalformedManifestError]
        sig do
          type_parameters(:M).params(path: Pathname, blk: T.proc.params(hash: JsonHash).returns(T.type_parameter(:M)))
            .returns(T.type_parameter(:M))
        end
        def read_file(path, &blk)
          raise MissingManifestError, "no #{path.basename} at #{path.dirname}" unless path.file?

          document = JSON.parse(path.read)
          raise MalformedManifestError, "#{path}: expected a JSON object" unless document.is_a?(Hash)

          yield(document)
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
          raise MalformedManifestError, "#{path}: #{e.message}"
        end
      end

      # `build-id.json`: what one artifact in the store was packaged from.
      # Current when the tree it was packaged from was clean and is the
      # tree as it is now, so `package` rebuilds on any change and `deploy`
      # refuses a stale one.
      class Artifact
        extend T::Sig
        extend T::Helpers
        include Manifest
        final!
        include Dev::ValueEquality::Derived

        FILE_NAME = "build-id.json"

        sig(:final) { override.returns(Stamp) }
        attr_reader :stamp

        # @return [Build] the build this artifact is of
        sig(:final) { returns(Build) }
        attr_reader :build

        # @return [GitState] the tree the artifact was packaged from
        sig(:final) { returns(GitState) }
        attr_reader :state

        # @return [Time] when the packager finished
        sig(:final) { returns(Time) }
        attr_reader :packaged_at

        # @return [String] the builder that made the install (`script`, or an
        #   integration's name)
        sig(:final) { returns(String) }
        attr_reader :builder

        # @return [String, nil] the builder's own version (an engine tag),
        #   when it has one
        sig(:final) { returns(T.nilable(String)) }
        attr_reader :builder_version

        sig(:final) { returns(BuildId) }
        attr_reader :build_id

        # @return [String] the archive's file name beside this manifest
        sig(:final) { returns(String) }
        attr_reader :archive

        # @return [String] the archive's SHA-256, hex
        sig(:final) { returns(String) }
        attr_reader :archive_sha256

        sig(:final) do
          params(
            stamp: Stamp,
            build: Build,
            state: GitState,
            packaged_at: Time,
            builder: String,
            builder_version: T.nilable(String),
            build_id: BuildId,
            archive: String,
            archive_sha256: String,
          ).void
        end
        def initialize(stamp:, build:, state:, packaged_at:, builder:, builder_version:, build_id:, archive:, archive_sha256:)
          @stamp = stamp
          @build = build
          @state = state
          @packaged_at = T.let(packaged_at.utc, Time)
          @builder = builder
          @builder_version = builder_version
          @build_id = build_id
          @archive = archive
          @archive_sha256 = archive_sha256
          freeze
        end

        class << self
          extend T::Sig

          # The manifest in an artifact's directory.
          #
          # @param dir [Pathname] the artifact's directory
          # @param targets [Array<Target>] the project's declared targets
          # @return [Artifact]
          # @raise [MissingManifestError]
          # @raise [MalformedManifestError]
          sig(:final) { params(dir: Pathname, targets: T::Array[Target]).returns(Artifact) }
          def read(dir, targets:)
            Manifest.read_file(dir / FILE_NAME) { |hash| from_json_hash(hash, targets:) }
          end

          # @param hash [Hash] the parsed document
          # @param targets [Array<Target>]
          # @return [Artifact]
          # @raise [KeyError, TypeError, ArgumentError] on a malformed shape
          #   (Manifest.read_file maps them)
          sig(:final) { params(hash: JsonHash, targets: T::Array[Target]).returns(Artifact) }
          def from_json_hash(hash, targets:)
            new(
              stamp: Stamp.from_json_hash(hash.fetch("stamp")),
              build: Build.parse(hash.fetch("build").to_s, targets),
              state: GitState.new(sha: hash.fetch("sha")&.to_s, dirty: hash.fetch("dirty") == true),
              packaged_at: Time.iso8601(hash.fetch("packaged_at").to_s),
              builder: hash.fetch("builder").to_s,
              builder_version: hash.fetch("builder_version")&.to_s,
              build_id: BuildId.new(hash.fetch("build_id").to_s),
              archive: hash.fetch("archive").to_s,
              archive_sha256: hash.fetch("archive_sha256").to_s,
            )
          end
        end

        sig(:final) { override.returns(String) }
        def file_name
          FILE_NAME
        end

        # Packaged from a clean tree at the commit the tree is at now.
        sig(:final) { override.params(state: GitState).returns(T::Boolean) }
        def current?(state)
          @state.clean? && @state == state
        end

        sig(:final) { override.returns(JsonHash) }
        def to_json_hash
          {
            "stamp" => @stamp.to_json_hash,
            "build" => @build.name,
            "sha" => @state.sha,
            "dirty" => @state.dirty,
            "packaged_at" => @packaged_at.strftime(INSTANT_FORMAT),
            "builder" => @builder,
            "builder_version" => @builder_version,
            "build_id" => @build_id.to_s,
            "archive" => @archive,
            "archive_sha256" => @archive_sha256,
          }
        end

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          [to_json_hash]
        end
      end

      # `release.json`: what a cut made: the tag, its commit, and the
      # archives attached to the GitHub release with the build ids they
      # were packaged under. Always current: the tag is immutable.
      class Release
        extend T::Sig
        extend T::Helpers
        include Manifest
        final!
        include Dev::ValueEquality::Derived

        FILE_NAME = "release.json"

        # One archive of the release: which build, the asset's name
        # (`<build>-<version>.<ext>`), its digest and provenance.
        class Archive < T::Struct
          extend T::Sig

          const :build, Build
          const :name, String
          const :sha256, String
          const :build_id, BuildId

          class << self
            extend T::Sig

            # @param hash [Hash] one entry of `archives`
            # @param targets [Array<Target>]
            # @return [Archive]
            # @raise [KeyError, TypeError, ArgumentError] on a malformed shape
            sig { params(hash: JsonHash, targets: T::Array[Target]).returns(Archive) }
            def from_json_hash(hash, targets:)
              new(
                build: Build.parse(hash.fetch("build").to_s, targets),
                name: hash.fetch("name").to_s,
                sha256: hash.fetch("sha256").to_s,
                build_id: BuildId.new(hash.fetch("build_id").to_s),
              )
            end
          end

          # @return [Hash] the JSON shape
          sig { returns(JsonHash) }
          def to_json_hash
            { "build" => build.name, "name" => name, "sha256" => sha256, "build_id" => build_id.to_s }
          end
        end

        sig(:final) { override.returns(Stamp) }
        attr_reader :stamp

        # @return [String] the release's tag (`v1.2.0`)
        sig(:final) { returns(String) }
        attr_reader :tag

        # @return [String] the commit the tag points at
        sig(:final) { returns(String) }
        attr_reader :sha

        # @return [Array<Archive>] in release-target order
        sig(:final) { returns(T::Array[Archive]) }
        attr_reader :archives

        sig(:final) { params(stamp: Stamp, tag: String, sha: String, archives: T::Array[Archive]).void }
        def initialize(stamp:, tag:, sha:, archives:)
          @stamp = stamp
          @tag = tag
          @sha = sha
          @archives = T.let(archives.freeze, T::Array[Archive])
          freeze
        end

        class << self
          extend T::Sig

          # The manifest in a release's directory.
          #
          # @param dir [Pathname] where the release's assets were gathered
          # @param targets [Array<Target>] the project's declared targets
          # @return [Release]
          # @raise [MissingManifestError]
          # @raise [MalformedManifestError]
          sig(:final) { params(dir: Pathname, targets: T::Array[Target]).returns(Release) }
          def read(dir, targets:)
            Manifest.read_file(dir / FILE_NAME) { |hash| from_json_hash(hash, targets:) }
          end

          # @param hash [Hash] the parsed document
          # @param targets [Array<Target>]
          # @return [Release]
          # @raise [KeyError, TypeError, ArgumentError] on a malformed shape
          #   (Manifest.read_file maps them)
          sig(:final) { params(hash: JsonHash, targets: T::Array[Target]).returns(Release) }
          def from_json_hash(hash, targets:)
            archives = hash.fetch("archives")
            raise TypeError, "archives: expected a list" unless archives.is_a?(Array)

            new(
              stamp: Stamp.from_json_hash(hash.fetch("stamp")),
              tag: hash.fetch("tag").to_s,
              sha: hash.fetch("sha").to_s,
              archives: archives.map { |entry| Archive.from_json_hash(entry, targets:) },
            )
          end
        end

        sig(:final) { override.returns(String) }
        def file_name
          FILE_NAME
        end

        # The tag is immutable: a release is never stale.
        sig(:final) { override.params(state: GitState).returns(T::Boolean) }
        def current?(state)
          _ = state
          true
        end

        # The release's archive of a build, or nil when the release carries
        # none — what `deploy --release` selects by, as it reads the store
        # by Store#artifact.
        #
        # @param build [Build]
        # @return [Archive, nil]
        sig(:final) { params(build: Build).returns(T.nilable(Archive)) }
        def archive(build)
          @archives.find { |entry| entry.build == build }
        end

        sig(:final) { override.returns(JsonHash) }
        def to_json_hash
          { "stamp" => @stamp.to_json_hash, "tag" => @tag, "sha" => @sha, "archives" => @archives.map(&:to_json_hash) }
        end

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          [to_json_hash]
        end
      end
    end
  end
end
