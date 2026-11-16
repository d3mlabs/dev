# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Lifecycle
    # A workflow dev ships under `share/workflows/` as a project carries it:
    # copied verbatim to `.github/workflows/<name>` and committed. dev never
    # writes it into the project; a verb that needs it and finds it missing
    # refuses with the copy named, which this type spells once for every
    # shipped workflow.
    class ShippedWorkflow
      extend T::Sig

      # dev's own copies, relative to this file (lib/dev/lifecycle/ → the
      # repo or libexec root), the installed location under brew.
      SHARE_DIR = T.let(
        Pathname(File.expand_path(File.join(T.must(__dir__), "..", "..", "..", "share", "workflows"))),
        Pathname,
      )
      # Where a project carries its copies, relative to its root.
      PROJECT_DIR = T.let(Pathname(".github/workflows"), Pathname)

      sig { returns(String) }
      attr_reader :file_name

      # @param file_name [String] the workflow's file name, the same on both sides
      # @param root [Pathname] the project root
      sig { params(file_name: String, root: Pathname).void }
      def initialize(file_name:, root:)
        @file_name = file_name
        @root = root
      end

      # @return [Pathname] dev's own copy
      sig { returns(Pathname) }
      def source
        SHARE_DIR / @file_name
      end

      # @return [Pathname] the project's copy, relative to its root
      sig { returns(Pathname) }
      def project_path
        PROJECT_DIR / @file_name
      end

      # @return [Pathname] the project's copy
      sig { returns(Pathname) }
      def path
        @root / project_path
      end

      # @return [Boolean] whether the project carries the copy
      sig { returns(T::Boolean) }
      def installed?
        path.file?
      end

      # The shell line that puts the copy in place, as a refusal names it.
      #
      # @return [String]
      sig { returns(String) }
      def copy_instruction
        "mkdir -p #{PROJECT_DIR} && cp #{source} #{project_path}"
      end
    end
  end
end
