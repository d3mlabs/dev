# typed: strict
# frozen_string_literal: true

require "pathname"

require "dev/deps/artifact_store"
require "dev/deps/dependency"
require "dev/deps/gh_integration"
require "dev/deps/local_store"
require "dev/lifecycle/release_tag"
require "dev/stream"

module Dev
  # What of a stream this host has installed. A stream's head is installed
  # as the gh tree every gh pin becomes — `~/.dev/gh/<owner>/<repo>/<tag>`
  # in the artifact store, version-keyed and immutable, installed
  # self-contained (Deps::GhIntegration) — so "installed" is read from
  # the store and recorded nowhere: the release tags of the series with a
  # published tree there, the greatest of them being where the hook last
  # brought the host. Also the one derivation of the pin a head installs
  # as, shared by the follower that installs it and the status that
  # reports it.
  class StreamStore
    extend T::Sig

    # The group the pin is recorded under: a tool, run by jobs.
    GROUP = :app

    # A source tree published as-is: the release's tree is the tool,
    # installed self-contained (Deps::SelfContainedTree).
    BUILD = "none"

    # @param store [Deps::ArtifactStore] where published trees live
    sig { params(store: Deps::ArtifactStore).void }
    def initialize(store: Deps::LocalStore.new)
      @store = store
    end

    # The gh pin a stream's head installs as: the repo's tree at the
    # release tag, published as-is — the shape a tag pin with
    # `build: :none` takes, so the one install path serves both.
    #
    # @param stream [Dev::Stream]
    # @param head [Dev::Stream::Head]
    # @return [Deps::Dependency]
    sig { params(stream: Stream, head: Stream::Head).returns(Deps::Dependency) }
    def dependency(stream, head)
      Deps::Dependency.new(
        name: stream.name, integration: Stream::CHANNEL.to_sym, group: GROUP,
        version: head.tag, hash: nil, source: head.commit,
        metadata: { "repo" => stream.repo, "build" => BUILD, "commit" => head.commit },
      )
    end

    # The published tree of a stream's head, or nil when it is not
    # installed.
    #
    # @param stream [Dev::Stream]
    # @param head [Dev::Stream::Head]
    # @return [Pathname, nil]
    sig { params(stream: Stream, head: Stream::Head).returns(T.nilable(Pathname)) }
    def tree(stream, head)
      @store.tree(Deps::GhIntegration.tree_key(dependency(stream, head)))
    end

    # The greatest release version of the stream's series with a
    # published tree on this host, or nil when none of the series is.
    #
    # @param stream [Dev::Stream]
    # @return [String, nil] a version, `1.2.0`
    sig { params(stream: Stream).returns(T.nilable(String)) }
    def installed(stream)
      tags = @store.tree_versions(Deps::GhIntegration.tree_base(stream.repo))
      published = tags.select { |tag| stream.includes_tag?(tag) && tree(stream, Stream::Head.new(version: version_of(tag), commit: "")) }
      greatest = published.max_by { |tag| Gem::Version.new(version_of(tag)) }
      greatest && version_of(greatest)
    end

    private

    # @param tag [String] `v1.2.0`
    # @return [String] `1.2.0`
    sig { params(tag: String).returns(String) }
    def version_of(tag)
      tag.delete_prefix(Lifecycle::ReleaseTag::PREFIX)
    end
  end
end
