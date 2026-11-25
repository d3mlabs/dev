# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Lifecycle
    # The text of a `builder:` or `packager:` script as the project
    # declared it: the command line, plus the contents of each file under
    # the project root the line names (`./bin/build.sh`, `sh ./build.sh`).
    # A declaration is usually an invocation of a script file, so a check
    # for what the script reads has to see the file, not only the line that
    # runs it. Files the script sources or calls in turn are not followed:
    # the check is a courtesy, not a proof.
    #
    # The command and the project root are fixed for a checkout; the files
    # are read when asked, so the check sees the script as it is then.
    class ScriptSource
      extend T::Sig

      # @param command [String] the script's command line as declared
      # @param project_root [Pathname] where the script runs, and where the
      #   files it names resolve
      sig { params(command: String, project_root: Pathname).void }
      def initialize(command:, project_root:)
        @command = command
        @project_root = project_root
      end

      # Whether the command line, or a file it names, contains the word.
      #
      # @param word [String] an exact substring (`DEV_INSTALL`)
      # @return [Boolean]
      sig { params(word: String).returns(T::Boolean) }
      def mentions?(word)
        return true if @command.include?(word)

        # Bytes, not text: a word on the line may name a data file the
        # script takes, and a byte search never trips on its encoding.
        named_files.any? { |file| File.binread(file).include?(word) }
      end

      private

      # The regular files under the project root the command line names,
      # word by word. Whitespace is the split: a quoted path with a space
      # in it is not followed, and nothing else on the line (a flag, a
      # literal) resolves to a file.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def named_files
        @command.split.filter_map do |word|
          candidate = @project_root / word
          candidate if candidate.file?
        end
      end
    end
  end
end
