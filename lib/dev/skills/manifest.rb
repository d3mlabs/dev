# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "layout"

module Dev
  module Skills
    # The per-root record of what dev materialized there: one entry per
    # link, with the channel it came from and the package/version it was
    # minted from. Written on every materialization pass; read back on the
    # next to prune exactly (previous minus next — no prefix heuristics, no
    # risk of touching a link dev did not mint) and by `dev skills status`
    # for provenance (the version comes from the resolved package set at
    # mint time, not from parsing `readlink`).
    #
    # One manifest per root, shared by every channel landing there (dev's
    # own and the org corpus both land user-globally): a channel's pass
    # replaces its own records and leaves the other channels' alone.
    #
    # Internal format — consumers go through the command surface, never
    # read the file.
    class Manifest
      extend T::Sig

      SCHEMA = 1

      # One materialized link.
      class Record < T::Struct
        extend T::Sig

        const :name, String                  # the skill's folder name (its frontmatter `name`)
        const :integration, String           # the channel that minted it
        const :link, String                  # path relative to the root
        const :source, String                # absolute skill dir the link points at
        const :package, T.nilable(String), default: nil
        const :version, T.nilable(String), default: nil

        # @param root [Pathname] the manifest's root
        # @return [Pathname] the link's absolute path
        sig { params(root: Pathname).returns(Pathname) }
        def link_path(root)
          root / link
        end

        # @return [Hash] the JSON shape
        sig { returns(T::Hash[String, T.untyped]) }
        def to_json_hash
          {
            "name" => name, "integration" => integration, "package" => package, "version" => version,
            "link" => link, "source" => source,
          }
        end

        class << self
          extend T::Sig

          # @param hash [Hash] one entry of the JSON shape
          # @return [Record]
          sig { params(hash: T::Hash[String, T.untyped]).returns(Record) }
          def from_json_hash(hash)
            new(
              name: hash.fetch("name"), integration: hash.fetch("integration"),
              link: hash.fetch("link"), source: hash.fetch("source"),
              package: hash["package"], version: hash["version"],
            )
          end
        end
      end

      # @return [Pathname] the root this manifest describes
      sig { returns(Pathname) }
      attr_reader :root

      # @return [Array<Record>] every materialized link under the root
      sig { returns(T::Array[Record]) }
      attr_reader :records

      # @param root [Pathname, String]
      # @param records [Array<Record>]
      sig { params(root: T.any(Pathname, String), records: T::Array[Record]).void }
      def initialize(root:, records: [])
        @root = T.let(Pathname(root), Pathname)
        @records = records
      end

      class << self
        extend T::Sig

        # The manifest on disk for a root, or an empty one when none has been
        # written yet — or when the file is unreadable (a corrupt manifest
        # means dev forgets what it placed and re-records on the next pass;
        # it never blocks materialization).
        #
        # @param root [Pathname, String]
        # @return [Manifest]
        sig { params(root: T.any(Pathname, String)).returns(Manifest) }
        def read(root)
          file = Layout.manifest_file(root)
          return new(root: root) unless file.file?

          data = JSON.parse(file.read)
          records = Array(data["skills"]).map { |entry| Record.from_json_hash(entry) }
          new(root: root, records: records)
        rescue JSON::ParserError, KeyError, TypeError, SystemCallError
          new(root: root)
        end
      end

      # @param integration [String] a channel name
      # @return [Array<Record>] that channel's records, sorted by link
      sig { params(integration: String).returns(T::Array[Record]) }
      def for_integration(integration)
        @records.select { |record| record.integration == integration }.sort_by(&:link)
      end

      # A new manifest with one channel's records replaced.
      #
      # @param integration [String] the channel whose records to replace
      # @param records [Array<Record>] its new records
      # @return [Manifest]
      sig { params(integration: String, records: T::Array[Record]).returns(Manifest) }
      def replacing(integration, records)
        kept = @records.reject { |record| record.integration == integration }
        Manifest.new(root: @root, records: (kept + records).sort_by { |r| [r.integration, r.link] })
      end

      # Write the manifest beside the links. Creates the root if needed.
      #
      # @param now [Time] the generation timestamp (injectable for tests)
      # @return [void]
      sig { params(now: Time).void }
      def write(now: Time.now)
        file = Layout.manifest_file(@root)
        file.dirname.mkpath
        file.write(JSON.pretty_generate(to_json_hash(now)) + "\n")
      end

      # @param now [Time]
      # @return [Hash] the JSON shape
      sig { params(now: Time).returns(T::Hash[String, T.untyped]) }
      def to_json_hash(now)
        {
          "schema" => SCHEMA,
          "generated_at" => now.utc.iso8601,
          "root" => @root.to_s,
          "skills" => @records.map(&:to_json_hash),
        }
      end
    end
  end
end
