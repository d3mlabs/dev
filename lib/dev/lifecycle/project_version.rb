# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/gemfile_lock"
require_relative "build_id"

module Dev
  module Lifecycle
    # The semver half of a BuildId: the project's own version when it keeps
    # one in source as a `VERSION` file at its root (dev's convention, and
    # what `release` bumps — dev#424), BuildId::DEFAULT_SEMVER otherwise. A
    # project without a version still gets build ids that sort and compare;
    # only the leading number is uninformative.
    #
    # A gem whose gemspec reads `VERSION` has a **mirror** of it: bundler
    # records the gem's own version in `Gemfile.lock` (GemfileLock — the
    # `PATH` spec and the `CHECKSUMS` entry), and a bump that moves one
    # file and not the other leaves a lock the next `bundle` rewrites — a
    # dirty tree right after the release commit (dev's `bin/release.rb`
    # bumped both for that reason; dev#429 keeps it so, dev#521 the
    # checksum line). The bump therefore writes `VERSION` and, when the
    # lock mirrors it, the own gem's lines.
    #
    # The **next** version is the one part of a `major.minor.patch` bumped
    # and the parts after it zeroed — what `release` cuts when given no
    # version, or a bump word (dev#525; `bin/release.rb` bumped the patch).
    # Only a three-number version has a next: a pre-release or anything
    # else is released by name.
    module ProjectVersion
      FILE_NAME = "VERSION"
      GEMFILE_LOCK = GemfileLock::FILE_NAME

      # The version in source is not `major.minor.patch`, so no part of it
      # can be bumped.
      class NotSemverError < ArgumentError; end

      # The part of a `major.minor.patch` a bump moves — `release`'s bump
      # words, as the operator types them.
      class Part < T::Enum
        enums do
          Major = new("major")
          Minor = new("minor")
          Patch = new("patch")
        end

        # @return [Integer] the part's position in the three numbers
        sig { returns(Integer) }
        def index
          case self
          when Major then 0
          when Minor then 1
          when Patch then 2
          else T.absurd(self)
          end
        end
      end

      SEMVER = /\A(\d+)\.(\d+)\.(\d+)\z/

      class << self
        extend T::Sig

        # The version after +current+ with +part+ bumped: `1.1.9` → `1.1.10`
        # (patch), `1.2.0` (minor), `2.0.0` (major).
        #
        # @param current [String] a `major.minor.patch`
        # @param part [Part]
        # @return [String]
        # @raise [NotSemverError] +current+ is not three numbers
        sig { params(current: String, part: Part).returns(String) }
        def next(current, part)
          match = SEMVER.match(current)
          raise NotSemverError, "#{current.inspect} is not major.minor.patch — give the version to release" unless match

          numbers = match.captures.map(&:to_i)
          numbers.each_with_index.map do |number, index|
            if index < part.index then number
            elsif index == part.index then number + 1
            else 0
            end
          end.join(".")
        end

        # The files a bump of the version from +current+ rewrites, relative
        # to the root: `VERSION`, and `Gemfile.lock` when its own gem is at
        # that version.
        #
        # @param root [Pathname] the project root
        # @param current [String] the version in source now
        # @return [Array<String>]
        sig { params(root: Pathname, current: String).returns(T::Array[String]) }
        def files(root, current:)
          lock = root / GEMFILE_LOCK
          mirrored = lock.file? && GemfileLock.new(lock.read).own_version == current
          mirrored ? [FILE_NAME, GEMFILE_LOCK] : [FILE_NAME]
        end

        # @param root [Pathname] the project root
        # @return [String] the file's first line, or the default
        sig { params(root: Pathname).returns(String) }
        def read(root)
          declared(root) || BuildId::DEFAULT_SEMVER
        end

        # The version the project keeps in source, or nil when it keeps
        # none — the distinction `release` reads: a project with a
        # `VERSION` file gets a bump commit, one without is tagged as is.
        #
        # @param root [Pathname] the project root
        # @return [String, nil] the file's first line, trimmed; nil when
        #   there is no file or it is blank
        sig { params(root: Pathname).returns(T.nilable(String)) }
        def declared(root)
          file = root / FILE_NAME
          return nil unless file.file?

          version = file.read.lines.first.to_s.strip
          version.empty? ? nil : version
        end

        # Write the version the project keeps in source — the bump of a
        # release cut — into `VERSION` and its `Gemfile.lock` mirror when
        # the lock has one (ProjectVersion.files).
        #
        # @param root [Pathname] the project root
        # @param version [String]
        # @return [void]
        sig { params(root: Pathname, version: String).void }
        def write(root, version)
          current = declared(root)
          (root / FILE_NAME).write("#{version}\n")
          return if current.nil? || !files(root, current:).include?(GEMFILE_LOCK)

          lock = root / GEMFILE_LOCK
          lock.write(GemfileLock.new(lock.read).with_own_version(version))
        end
      end
    end
  end
end
