# typed: strict
# frozen_string_literal: true

require "find"
require "pathname"
require_relative "file_pattern"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # Which files of a stage ship: the `archive` packager's `files:`, a list
    # of FilePatterns applied in order, the last matching one deciding. The
    # list starts from nothing when it has a positive pattern and from
    # everything when it has none, so an exclude-only list reads like a
    # `.npmignore`. Paths are never rerooted: a selected file keeps its
    # stage path in the archive.
    #
    # The empty list is the identity — the whole stage, what an omitted
    # `files:` means — and never refuses: a stage with nothing in it is
    # the packager's EmptyInstallError, not a selection's.
    class FileSelection
      extend T::Sig
      include Dev::ValueEquality::Derived

      # The patterns selected no file of the stage.
      class EmptySelectionError < RuntimeError
        extend T::Sig

        # @param selection [FileSelection]
        # @param stage [Pathname]
        sig { params(selection: FileSelection, stage: Pathname).void }
        def initialize(selection:, stage:)
          super("files: #{selection.patterns.join(" ")} selects nothing in #{stage}")
        end
      end

      # How `dev help` spells a selection, after the archive's form.
      RENDERED = ", files: "

      class << self
        extend T::Sig

        # The identity: every file of the stage.
        #
        # @return [FileSelection]
        sig { returns(FileSelection) }
        def all
          new(patterns: [])
        end

        # @param sources [Array<String>] the patterns as dev.yml lists them
        # @return [FileSelection]
        # @raise [FilePattern::InvalidFilePatternError]
        sig { params(sources: T::Array[String]).returns(FileSelection) }
        def parse(sources)
          new(patterns: sources.map { |source| FilePattern.new(source:) })
        end
      end

      sig { returns(T::Array[FilePattern]) }
      attr_reader :patterns

      # @param patterns [Array<FilePattern>] in the order they apply
      sig { params(patterns: T::Array[FilePattern]).void }
      def initialize(patterns:)
        @patterns = patterns
        # No positive pattern: everything is in until a pattern takes it out.
        @included_by_default = T.let(patterns.all?(&:negated?), T::Boolean)
      end

      # Whether this is the identity, the whole stage.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def whole?
        patterns.empty?
      end

      # The files of +stage+ the patterns select, as paths relative to it,
      # sorted. Symlinks count as files, whatever they point at; a
      # directory is never selected by itself, only through its files.
      #
      # @param stage [Pathname] the directory the patterns are matched in
      # @return [Array<Pathname>]
      # @raise [EmptySelectionError] when the patterns select nothing;
      #   never for the identity
      sig { params(stage: Pathname).returns(T::Array[Pathname]) }
      def select(stage)
        selected = files_under(stage).select { |relative| included?(relative) }
        raise EmptySelectionError.new(selection: self, stage:) if selected.empty? && !whole?

        selected
      end

      # The selection as `dev help` renders it after the archive's form:
      # nothing for the identity, the patterns as written otherwise.
      #
      # @return [String] "" or ", files: bin lib !lib/scratch"
      sig { returns(String) }
      def to_s
        whole? ? "" : "#{RENDERED}#{patterns.join(" ")}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [patterns]
      end

      private

      # Whether the last pattern matching +relative+ includes it — or, when
      # none does, the list's starting point.
      #
      # @param relative [Pathname]
      # @return [Boolean]
      sig { params(relative: Pathname).returns(T::Boolean) }
      def included?(relative)
        patterns.reduce(@included_by_default) do |included, pattern|
          pattern.matches?(relative) ? !pattern.negated? : included
        end
      end

      # Every file and symlink under +stage+, relative to it, sorted.
      # Symlinks are not followed: one to a directory is one entry.
      #
      # @param stage [Pathname]
      # @return [Array<Pathname>]
      sig { params(stage: Pathname).returns(T::Array[Pathname]) }
      def files_under(stage)
        stage.find.select { |path| path.symlink? || path.file? }.map { |path| path.relative_path_from(stage) }.sort
      end
    end
  end
end
