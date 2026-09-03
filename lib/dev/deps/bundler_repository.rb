# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # Fact universe over the bundler-materialized Gemfile.lock.
    #
    # Gems are a first-class dev-managed dependency type whose backing tool is
    # bundler — just as brew backs :brew and gh backs :gh. BundlerLocker runs
    # the whole-set solve (`bundle lock`); this repository reads the resulting
    # pins back. Each gem's universe is a singleton: the one version the joint
    # solve chose, with the CHECKSUMS integrity digest when the lockfile has
    # one. Transitive gems are left to `bundle install` (they live in
    # Gemfile.lock, not deps.lock).
    class BundlerRepository < Repository
      extend T::Sig

      # The gem is absent from Gemfile.lock — the lock step didn't cover it.
      class MissingGemError < PackageNotFoundError; end

      LOCKFILE = "Gemfile.lock"

      # @param project_root [Pathname, String] root the Gemfile.lock lives in
      sig { params(project_root: T.any(Pathname, String)).void }
      def initialize(project_root:)
        @project_root = T.let(Pathname(project_root), Pathname)
        @pins = T.let(nil, T.nilable(T::Hash[String, T::Hash[Symbol, T.nilable(String)]]))
      end

      # Report a gem's locked pin from Gemfile.lock as a singleton universe.
      #
      # @param id [PackageId] name is the gem name
      # @param filter [Hash] unused; the lockfile needs no locator
      # @return [Package] a singleton universe
      # @raise [MissingGemError] if the gem is absent from the parsed Gemfile.lock
      sig { override.params(id: PackageId, filter: T::Hash[String, T.untyped]).returns(Package) }
      def find(id, filter: {})
        pin = pins.fetch(id.name) do
          raise MissingGemError,
            "gem #{id.name.inspect} is not in #{LOCKFILE} — run `dev update-deps`"
        end

        Package.new(
          id: id,
          versions: [PackageVersion.new(version: T.must(pin[:version]), digest: pin[:hash])],
        )
      end

      private

      # Lazily ensure the lockfile has been parsed.
      #
      # @return [Hash{String => Hash}]
      sig { returns(T::Hash[String, T::Hash[Symbol, T.nilable(String)]]) }
      def pins
        @pins ||= parse_lockfile
      end

      # Parse the generated Gemfile.lock into name => { version:, hash: } pins.
      #
      # Reads the lockfile text directly rather than via Bundler's parser so the
      # pins are independent of the installed bundler version. Top-level specs
      # (the `name (version)` lines indented four spaces under each source's
      # `specs:` block) give the versions; the CHECKSUMS section, when present,
      # gives the integrity hash.
      #
      # @return [Hash{String => Hash}]
      sig { returns(T::Hash[String, T::Hash[Symbol, T.nilable(String)]]) }
      def parse_lockfile
        return {} unless lockfile_path.exist?

        contents = lockfile_path.read
        checksums = parse_checksums(contents)
        parse_spec_versions(contents).each_with_object({}) do |(name, version), pins|
          pins[name] = { version:, hash: checksums[name] }
        end
      end

      # Extract top-level locked versions from the source specs blocks. A
      # top-level spec is indented exactly four spaces (six-space lines are that
      # spec's own dependency constraints and are skipped).
      #
      # @param contents [String] raw Gemfile.lock contents
      # @return [Hash{String => String}] gem name => locked version
      sig { params(contents: String).returns(T::Hash[String, String]) }
      def parse_spec_versions(contents)
        versions = {}
        in_specs = T.let(false, T::Boolean)
        contents.each_line do |line|
          if line.match?(/^\s+specs:\s*$/)
            in_specs = true
          elsif in_specs && (match = line.match(/^ {4}(\S+) \(([^)]+)\)\s*$/))
            # A gem can appear once per platform (e.g. "ffi (1.17.4)" and
            # "ffi (1.17.4-arm64-darwin)"); keep the first (platform-agnostic) one.
            versions[match[1]] ||= match[2]
          elsif in_specs && line.match?(/^\S/)
            in_specs = false
          end
        end
        versions
      end

      # Parse the optional CHECKSUMS section into name => "SHA256=<hex>". Absent on
      # older bundlers, in which case gems carry no integrity hash (bundler still
      # verifies the lock on install).
      #
      # @param contents [String] raw Gemfile.lock contents
      # @return [Hash{String => String}]
      sig { params(contents: String).returns(T::Hash[String, String]) }
      def parse_checksums(contents)
        section = contents[/^CHECKSUMS\n(.*?)(?:\n\n|\z)/m, 1]
        return {} unless section

        section.lines.each_with_object({}) do |line, checksums|
          match = line.match(/(\S+) \([^)]+\) sha256=(\h+)/)
          # Keep the first (platform-agnostic) checksum when a gem is listed per platform.
          checksums[match[1]] ||= "SHA256=#{match[2]}" if match
        end
      end

      # @return [Pathname]
      sig { returns(Pathname) }
      def lockfile_path
        @project_root / LOCKFILE
      end
    end
  end
end
