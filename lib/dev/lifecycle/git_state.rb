# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Lifecycle
    # The two git facts an artifact's provenance is made of: the commit the
    # working tree was packaged from and whether it carried uncommitted
    # changes. What a BuildId is derived from, what `build-id.json` records,
    # and what Manifest::Artifact#current? compares a stamp against.
    #
    # Outside a checkout (an exported tree, a repo with no commit yet) the
    # sha is unknown and the tree is never trusted as clean.
    class GitState < T::Struct
      extend T::Sig

      # `git status` failed inside what `git rev-parse` had just called a
      # checkout — the tree is in a state dev cannot describe.
      class GitStatusError < RuntimeError; end

      SHORT_SHA_LENGTH = 12

      # @return [String, nil] the short sha of HEAD; nil outside a checkout
      const :sha, T.nilable(String)
      # @return [Boolean] whether the tree has uncommitted changes (always
      #   true when the sha is unknown)
      const :dirty, T::Boolean

      class << self
        extend T::Sig

        # Read the working tree at a root.
        #
        # @param root [Pathname] the project root
        # @return [GitState]
        # @raise [GitStatusError]
        sig { params(root: Pathname).returns(GitState) }
        def read(root)
          sha, _err, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--short=#{SHORT_SHA_LENGTH}", "HEAD")
          return new(sha: nil, dirty: true) unless status.success?

          porcelain, err, status = Open3.capture3("git", "-C", root.to_s, "status", "--porcelain")
          raise GitStatusError, "git status failed in #{root}: #{err.strip}" unless status.success?

          new(sha: sha.strip, dirty: !porcelain.strip.empty?)
        end
      end

      # Whether the tree is at a known commit with nothing uncommitted —
      # the state an artifact must have been packaged from to be current.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def clean?
        !sha.nil? && !dirty
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(GitState) && sha == other.sha && dirty == other.dirty
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [GitState, sha, dirty].hash
      end
    end
  end
end
