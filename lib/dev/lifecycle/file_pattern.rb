# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # One pattern of an archive's `files:` list, in gitignore syntax: a
    # shell glob matched against a stage path with `fnmatch(3)`'s
    # FNM_PATHNAME (`*` stops at `/`), `**` spanning directories and `*`
    # matching dotfiles. A leading `!` negates; a trailing `/` matches
    # directories only; a `/` at the start or in the middle anchors the
    # pattern at the stage root, otherwise it matches at any depth. A
    # pattern that matches a directory matches every file under it — a
    # bare `bin` means bin's contents.
    #
    # Which files a list of these selects is FileSelection's.
    class FilePattern
      extend T::Sig
      include Dev::ValueEquality::Derived

      # A pattern with nothing to match: blank, or only `!` or `/`.
      class InvalidFilePatternError < ArgumentError; end

      NEGATION = "!"
      SEPARATOR = "/"
      ANY_DEPTH = "**/"
      # gitignore's semantics over fnmatch(3): `*` never crosses a `/`, and
      # matches a leading dot.
      FLAGS = T.let(File::FNM_PATHNAME | File::FNM_DOTMATCH, Integer)

      sig { returns(String) }
      attr_reader :source

      # @param source [String] the pattern as dev.yml spells it
      # @raise [InvalidFilePatternError]
      sig { params(source: String).void }
      def initialize(source:)
        @source = source
        body = source.strip
        @negated = T.let(body.start_with?(NEGATION), T::Boolean)
        body = body.delete_prefix(NEGATION)
        @directory_only = T.let(body.length > 1 && body.end_with?(SEPARATOR), T::Boolean)
        body = body.chomp(SEPARATOR)
        anchored = body.include?(SEPARATOR)
        body = body.delete_prefix(SEPARATOR)
        raise InvalidFilePatternError, "#{source.inspect} is not a pattern: nothing to match" if body.empty?

        @glob = T.let(anchored ? body : "#{ANY_DEPTH}#{body}", String)
      end

      # Whether the pattern removes what it matches from the selection.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def negated?
        @negated
      end

      # Whether the pattern matches +path+, a file's path relative to the
      # stage: the path itself, or any directory above it.
      #
      # @param path [Pathname] relative to the stage, never a directory
      # @return [Boolean]
      sig { params(path: Pathname).returns(T::Boolean) }
      def matches?(path)
        # descend yields the path's prefixes root-first, the file itself last.
        prefixes = path.descend.to_a
        candidates = @directory_only ? prefixes.first(prefixes.size - 1) : prefixes
        candidates.any? { |candidate| File.fnmatch?(@glob, candidate.to_s, FLAGS) }
      end

      # @return [String] the pattern as written
      sig { returns(String) }
      def to_s
        source
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [source]
      end
    end
  end
end
