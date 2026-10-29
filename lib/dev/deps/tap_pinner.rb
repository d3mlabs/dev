# typed: strict
# frozen_string_literal: true

require "fileutils"
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
    # to the commit — a full clone by a plain fetch, so it never becomes
    # shallow (brew refuses to update a shallow core).
    #
    # A pin is scoped when the caller wants it so: `pin!` remembers what
    # the tap was before its first pin, and `restore!` puts that back — a
    # tap dev created is removed, a developer's own clone returns to the
    # ref it was on. An image build pins and never restores: the image is
    # the artifact. A host converging one keg pins, installs and restores,
    # so brew reads its usual sources again (dev#356).
    class TapPinner
      extend T::Sig

      # What a tap was before dev first pinned it: this marker for "no
      # checkout", else the branch name or detached commit it was on.
      ABSENT = "absent"

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

      # @return [Pathname] brew's Library/Taps directory
      sig { returns(Pathname) }
      attr_reader :taps_root

      # @param taps_root [Pathname] brew's Library/Taps directory
      # @param remote_urls [Hash{String => String}] tap slug to clone URL,
      #   for taps whose remote is not github.com/<user>/homebrew-<repo>
      sig { params(taps_root: Pathname, remote_urls: T::Hash[String, String]).void }
      def initialize(taps_root:, remote_urls: {})
        @taps_root = taps_root
        @remote_urls = remote_urls
        @prior = T.let({}, T::Hash[String, String])
      end

      # Check the tap out at the commit, creating it if brew has not got it.
      # The state before the first pin is kept for `restore!`.
      #
      # @param tap [String] tap slug (e.g. "homebrew/core")
      # @param commit [String] the commit to pin
      # @return [void]
      # @raise [PinError] if a git step fails
      sig { params(tap: String, commit: String).void }
      def pin!(tap, commit)
        dir = tap_dir(tap)
        exists = (dir / ".git").exist?
        @prior[tap] ||= exists ? current_ref(dir) : ABSENT
        unless exists
          dir.mkpath
          git!(dir, tap, commit, "init", "-q")
          git!(dir, tap, commit, "remote", "add", "origin", remote_url(tap))
        end
        if exists && !shallow?(dir)
          git!(dir, tap, commit, "fetch", "-q", "origin", commit)
        else
          git!(dir, tap, commit, "fetch", "-q", "--depth", "1", "origin", commit)
        end
        git!(dir, tap, commit, "checkout", "-q", "--detach", commit)
      end

      # Put the tap back as it was before its first `pin!`: removed when dev
      # created it, checked out at its prior ref otherwise. A tap never
      # pinned is left alone.
      #
      # @param tap [String] tap slug
      # @return [void]
      # @raise [PinError] if the checkout fails
      sig { params(tap: String).void }
      def restore!(tap)
        prior = @prior.delete(tap)
        return unless prior

        dir = tap_dir(tap)
        if prior == ABSENT
          FileUtils.rm_rf(dir)
        else
          git!(dir, tap, prior, "checkout", "-q", prior)
        end
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

      # The ref a checkout is on: its branch, else the detached commit.
      #
      # @param dir [Pathname]
      # @return [String]
      sig { params(dir: Pathname).returns(String) }
      def current_ref(dir)
        branch, _err, status = T.unsafe(Open3).capture3("git", "-C", dir.to_s, "symbolic-ref", "-q", "--short", "HEAD")
        return branch.strip if status.success? && !branch.strip.empty?

        T.unsafe(Open3).capture3("git", "-C", dir.to_s, "rev-parse", "HEAD").fetch(0).strip
      end

      # @param dir [Pathname]
      # @return [Boolean] whether the checkout has a shallow boundary
      sig { params(dir: Pathname).returns(T::Boolean) }
      def shallow?(dir)
        out, _err, _status = T.unsafe(Open3).capture3("git", "-C", dir.to_s, "rev-parse", "--is-shallow-repository")
        out.strip == "true"
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
