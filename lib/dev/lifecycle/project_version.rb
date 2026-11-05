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
          file = root / FILE_NAME
          return BuildId::DEFAULT_SEMVER unless file.file?

          version = file.read.lines.first.to_s.strip
          version.empty? ? BuildId::DEFAULT_SEMVER : version
        end
      end
    end
  end
end
