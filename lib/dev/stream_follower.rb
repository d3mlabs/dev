# typed: strict
# frozen_string_literal: true

require "dev/deps/gh_integration"
require "dev/deps/local_store"
require "dev/stream"
require "dev/stream_head_lookup"
require "dev/stream_store"
require "dev/ui"

module Dev
  # What the job-started hook does: bring the host to the stream's head
  # and put it on the job's PATH. The head is read from the channel
  # (StreamHeadLookup) and installed as the gh tree its pin becomes
  # (StreamStore, Deps::GhIntegration) — the install is a no-op when the
  # tree is already published, the common case, and otherwise the tool's
  # full closure (its Ruby keg, its gems, its wrappers) lands before the
  # job's first step; a head that moved mid-job is seen by the next one.
  # The tree's `bin` is appended to `$GITHUB_PATH`, the file a hook
  # writes and the job's steps inherit, so `ai-flow` in a step is the
  # head's.
  class StreamFollower
    extend T::Sig

    # The variable the runner hands a hook for additions to the job's PATH.
    GITHUB_PATH = "GITHUB_PATH"

    # @param lookup [Dev::StreamHeadLookup] reads the head
    # @param store [Dev::StreamStore] derives the pin and finds the tree
    # @param integration [Deps::GhIntegration] installs the tree
    # @param github_path [String, nil] the `$GITHUB_PATH` file; nil outside a job
    # @param ui [Ui]
    sig do
      params(
        lookup: StreamHeadLookup, store: StreamStore, integration: Deps::GhIntegration,
        github_path: T.nilable(String), ui: Ui,
      ).void
    end
    def initialize(lookup: StreamHeadLookup.new, store: StreamStore.new,
                   integration: Deps::GhIntegration.new(repository: nil, store: Deps::LocalStore.new),
                   github_path: ENV.fetch(GITHUB_PATH, nil), ui: NoUi.new)
      @lookup = lookup
      @store = store
      @integration = integration
      @github_path = github_path
      @ui = ui
    end

    # Install the stream's head if it moved and export its bin.
    #
    # @param stream [Dev::Stream]
    # @return [Pathname] the head's installed tree
    # @raise [StreamHeadLookup::NoHeadError]
    # @raise [StreamHeadLookup::HeadNotReleasedError]
    # @raise [StreamHeadLookup::QueryError]
    # @raise [Deps::Integration::PartialInstallError] when the install fails
    sig { params(stream: Stream).returns(Pathname) }
    def follow!(stream)
      head = @lookup.head(stream)
      @ui.note("{{v}} #{stream} is at #{head.tag} (#{head.commit[0, 12]})")
      @integration.install_all([@store.dependency(stream, head)])
      tree = T.must(@store.tree(stream, head))
      export_bin(tree / "bin")
      tree
    end

    private

    # Put the tree's bin on the job's PATH — or, outside a job, say where
    # it is, so a hand run reports what the hook would have exported.
    #
    # @param bin [Pathname]
    # @return [void]
    sig { params(bin: Pathname).void }
    def export_bin(bin)
      github_path = @github_path
      if github_path
        File.open(github_path, "a") { |file| file.puts(bin) }
        @ui.note("{{v}} #{bin} exported to the job's PATH")
      else
        @ui.note("{{v}} #{bin} is the stream's bin (not in a job: $#{GITHUB_PATH} unset, nothing exported)")
      end
    end
  end
end
