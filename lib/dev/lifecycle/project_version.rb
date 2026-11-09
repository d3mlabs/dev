# typed: strict
# frozen_string_literal: true

require "pathname"
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
    # records the gem's own version in `Gemfile.lock`'s `PATH` section
    # (`dev (0.7.13)` under `remote: .`) and, since bundler 2.6, a second
    # time in its `CHECKSUMS` section (`dev (0.7.13)`, no digest for a
    # path gem). A bump that moves one and not the others leaves a lock
    # the next `bundle` rewrites — a dirty tree right after the release
    # commit (dev's `bin/release.rb` bumped both files for that reason;
    # dev#429 keeps it so, dev#521 the checksum line). The bump therefore
    # writes `VERSION` and, when the lock mirrors it, the gem's lines.
    #
    # The **next** version is the one part of a `major.minor.patch` bumped
    # and the parts after it zeroed — what `release` cuts when given no
    # version, or a bump word (dev#525; `bin/release.rb` bumped the patch).
    # Only a three-number version has a next: a pre-release or anything
    # else is released by name.
    module ProjectVersion
      FILE_NAME = "VERSION"
      GEMFILE_LOCK = "Gemfile.lock"

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
        # to the root: `VERSION`, and `Gemfile.lock` when its `PATH` section
        # records a gem at that version.
        #
        # @param root [Pathname] the project root
        # @param current [String] the version in source now
        # @return [Array<String>]
        sig { params(root: Pathname, current: String).returns(T::Array[String]) }
        def files(root, current:)
          lock = root / GEMFILE_LOCK
          mirrored = lock.file? && path_spec(current).match?(lock.read)
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
          text = lock.read
          match = T.must(path_spec(current).match(text))
          gem = T.must(match[:gem])
          text = text.sub(path_spec(current)) { "#{$~[:spec]}#{version}#{$~[:close]}" }
          text = text.sub(checksum_entry(gem, current)) { "#{$~[:entry]}#{version}#{$~[:close]}" }
          lock.write(text)
        end

        private

        # The line of `Gemfile.lock`'s `PATH` section recording a gem of
        # the project's own gemspec (`remote: .`) at a version: bundler's
        # layout, the gem line four spaces in under `specs:`, its
        # dependencies six.
        #
        # @param version [String]
        # @return [Regexp] with `spec` (up to the version, `gem` inside it) and `close` groups
        sig { params(version: String).returns(Regexp) }
        def path_spec(version)
          /^(?<spec>PATH\n  remote: \.\n  specs:\n(?:    .+\n)*?    (?<gem>\S+) \()#{Regexp.escape(version)}(?<close>\))$/
        end

        # The line of `Gemfile.lock`'s `CHECKSUMS` section (bundler ≥ 2.6)
        # recording the same gem at a version: two spaces in, and for a
        # path gem no digest after it. Absent from an older bundler's lock,
        # where the substitution is a no-op.
        #
        # @param gem [String] the gem's name, as the PATH spec has it
        # @param version [String]
        # @return [Regexp] with `entry` (up to the version) and `close` groups
        sig { params(gem: String, version: String).returns(Regexp) }
        def checksum_entry(gem, version)
          /^(?<entry>CHECKSUMS\n(?:  .+\n)*?  #{Regexp.escape(gem)} \()#{Regexp.escape(version)}(?<close>\))$/
        end
      end
    end
  end
end
