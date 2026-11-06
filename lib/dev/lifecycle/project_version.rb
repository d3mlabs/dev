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
    module ProjectVersion
      FILE_NAME = "VERSION"

      class << self
        extend T::Sig

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
        # release cut.
        #
        # @param root [Pathname] the project root
        # @param version [String]
        # @return [void]
        sig { params(root: Pathname, version: String).void }
        def write(root, version)
          (root / FILE_NAME).write("#{version}\n")
        end
      end
    end
  end
end
