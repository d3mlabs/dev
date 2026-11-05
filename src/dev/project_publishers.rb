# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/lifecycle"

module Dev
  # The publishers the project's lock contributes (dev#192 K5, dev#422):
  # the write side of every integration the lock reaches, by the `deploy`
  # channel each contributes — `steam` for a project pinning the
  # Steamworks SDK, `ficsit` for one pinning SML, `brew` for one whose
  # Ruby installs through brew. The lock is the only declaration, as it is
  # for the images (ProjectImages): a store is publishable exactly when
  # the project already depends on it, because the store *is* that
  # integration, both directions (ADR-0010). Nothing in dev.yml names a
  # publisher; a `deploy` child of a contributed channel's name configures
  # it (ChannelBinder).
  #
  # Reads deps.lock once, on first use; the Registry decides which entries
  # the pins reach.
  class ProjectPublishers
    extend T::Sig

    # @param root [Pathname] the checkout (its deps.lock is read, once)
    # @param entries [Array<Deps::Registry::Entry>] the registry table to
    #   read the write sides from (tests substitute one)
    sig { params(root: Pathname, entries: T::Array[Deps::Registry::Entry]).void }
    def initialize(root:, entries: Deps::Registry::INTEGRATIONS)
      @root = root
      @entries = entries
      @contributed = T.let(nil, T.nilable(T::Hash[String, Lifecycle::Publisher]))
    end

    # The contributed publishers by channel name, in registry order.
    #
    # @return [Hash{String => Lifecycle::Publisher}]
    # @raise [Deps::Lockfile::RetiredBuildLockError] the checkout still carries build-deps.lock
    sig { returns(T::Hash[String, Lifecycle::Publisher]) }
    def contributed
      @contributed ||= Deps::Registry.publishers(project_root: @root, pinned: pinned_types, entries: @entries)
    end

    private

    # The integration types the lock pins, each once.
    #
    # @return [Array<Symbol>]
    sig { returns(T::Array[Symbol]) }
    def pinned_types
      Deps::Lockfile.new(dir: @root).read.map(&:integration).uniq
    end
  end
end
