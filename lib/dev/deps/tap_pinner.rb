# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Deps
    # Checks a Homebrew tap out at a locked commit, in the directory brew
    # reads taps from (`<brew repository>/Library/Taps/<user>/homebrew-<repo>`).
    #
    # The checkout is a single-commit fetch (`git fetch --depth 1 origin
    # <commit>`), not a clone: homebrew-core's history is the cost that
    # made pinning taps impractical, and one commit of it is small. A tap
    # that already exists (a `brew tap` clone, or a previous pin) is moved
    # to the commit the same way.
    class TapPinner
      extend T::Sig

      # A git step of the pin failed: the remote lacks the commit, is
      # unreachable, or the tap directory is not writable.
      class PinError < StandardError
        extend T::Sig

        # @param tap [String] tap slug
        # @param commit [String] the commit being pinned
        # @param step [String] the git arguments that failed
        # @param stderr [String] git's stderr
        sig { params(tap: String, commit: String, step: String, stderr: String).void }
        def initialize(tap:, commit:, step:, stderr:)
          super("pinning #{tap} at #{commit}: git #{step} failed — #{stderr.strip}")
        end
      end

      # @param taps_root [Pathname] brew's Library/Taps directory
      # @param remote_urls [Hash{String => String}] tap slug to clone URL,
      #   for taps whose remote is not github.com/<user>/homebrew-<repo>
      sig { params(taps_root: Pathname, remote_urls: T::Hash[String, String]).void }
      def initialize(taps_root:, remote_urls: {})
        @taps_root = taps_root
        @remote_urls = remote_urls
      end

      # Check the tap out at the commit, creating it if brew has not got it.
      #
      # @param tap [String] tap slug (e.g. "homebrew/core")
      # @param commit [String] the commit to pin
      # @return [void]
      # @raise [PinError] if a git step fails
      sig { params(tap: String, commit: String).void }
      def pin!(tap, commit)
        dir = tap_dir(tap)
        unless (dir / ".git").exist?
          dir.mkpath
          git!(dir, tap, commit, "init", "-q")
          git!(dir, tap, commit, "remote", "add", "origin", remote_url(tap))
        end
        git!(dir, tap, commit, "fetch", "-q", "--depth", "1", "origin", commit)
        git!(dir, tap, commit, "checkout", "-q", "--detach", commit)
      end

      # The tap's clone URL: the configured one, else its GitHub repository
      # under brew's naming convention.
      #
      # @param tap [String] tap slug
      # @return [String]
      sig { params(tap: String).returns(String) }
      def remote_url(tap)
        @remote_urls.fetch(tap) do
          user, repo = tap.split("/", 2)
          "https://github.com/#{user}/homebrew-#{repo}"
        end
      end

      private

      # Where brew reads the tap from.
      #
      # @param tap [String] tap slug
      # @return [Pathname]
      sig { params(tap: String).returns(Pathname) }
      def tap_dir(tap)
        user, repo = tap.split("/", 2)
        @taps_root / T.must(user) / "homebrew-#{repo}"
      end

      # Run one git step in the tap directory.
      #
      # @param dir [Pathname] the tap directory
      # @param tap [String] tap slug, for the error
      # @param commit [String] the commit being pinned, for the error
      # @param args [Array<String>] git arguments
      # @return [void]
      # @raise [PinError] if git exits non-zero
      sig { params(dir: Pathname, tap: String, commit: String, args: String).void }
      def git!(dir, tap, commit, *args)
        _out, err, status = T.unsafe(Open3).capture3("git", "-C", dir.to_s, *args)
        return if status.success?

        raise PinError.new(tap:, commit:, step: args.join(" "), stderr: err)
      end
    end
  end
end
