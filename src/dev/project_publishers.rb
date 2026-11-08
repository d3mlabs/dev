# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/deps/tap"
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
  # the pins reach. The lock also says which **taps** the project pins
  # formulae from (each brew-family pin's `tap:`) — the brew publisher's
  # destination (dev#429), handed to the Registry's context beside the
  # root so the lock stays the one declaration.
  class ProjectPublishers
    extend T::Sig

    # The lock's key for the tap a brew-family pin comes from (absent for
    # a core formula).
    TAP_KEY = "tap"

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
      @contributed ||= begin
        pins = Deps::Lockfile.new(dir: @root).read
        Deps::Registry.publishers(project_root: @root, pinned: pinned_types(pins), taps: pinned_taps(pins), entries: @entries)
      end
    end

    # What this dev could contribute: each channel the table can ship to,
    # with the types a pin of which reaches it (Registry.publisher_reach) —
    # the lock plays no part. The ChannelBinder's diagnosis of a declared
    # channel the lock leaves protocol-less (dev#509).
    #
    # @return [Hash{String => Array<Symbol>}]
    sig { returns(T::Hash[String, T::Array[Symbol]]) }
    def reach
      Deps::Registry.publisher_reach(entries: @entries)
    end

    private

    # The integration types the lock pins, each once.
    #
    # @param pins [Array<Deps::Dependency>]
    # @return [Array<Symbol>]
    sig { params(pins: T::Array[Deps::Dependency]).returns(T::Array[Symbol]) }
    def pinned_types(pins) = pins.map(&:integration).uniq

    # The taps the lock pins formulae from, each once, in lock order.
    #
    # @param pins [Array<Deps::Dependency>]
    # @return [Array<Deps::Tap>]
    sig { params(pins: T::Array[Deps::Dependency]).returns(T::Array[Deps::Tap]) }
    def pinned_taps(pins)
      pins.filter_map { |pin| pin.metadata[TAP_KEY] }.uniq.map { |name| Deps::Tap.new(name: name.to_s) }
    end
  end
end
