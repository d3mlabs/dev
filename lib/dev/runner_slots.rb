# typed: strict
# frozen_string_literal: true

module Dev
  # How one host's slots at one scope are named (dev#470): N identical
  # runners with one label set, each its own dir, `_work` and service,
  # because a self-hosted runner executes one job at a time and N jobs at
  # once means N registrations. Nothing records that the slots belong
  # together — the names do (plans#26: inspected, never recorded): slot 1
  # is `<base>` — the runner's name, the hostname by default, which is
  # what one enrollment was called before slots existed, so an existing
  # enrollment is one slot by construction — and slot n is `<base>-<n>`.
  # Dirs follow the same shape beside slot 1's: `<dir>` and `<dir>-<n>`,
  # so every slot sits next to the first wherever that one lives
  # (RunnerDiscovery's `actions-runner-*` glob finds them all).
  class RunnerSlots
    extend T::Sig

    # `<base>-<n>`: the slot suffix a name may carry.
    SLOT_NAME = T.let(/\A(?<base>.+)-(?<slot>[1-9]\d*)\z/, Regexp)

    # Slot 1's runner name, and the stem of the rest.
    sig { returns(String) }
    attr_reader :base

    # Slot 1's install dir, the stem of the rest.
    sig { returns(String) }
    attr_reader :dir

    class << self
      extend T::Sig

      # The base a runner name belongs to: the name without its slot suffix.
      #
      # @param name [String] a runner's GitHub-side name
      # @return [String]
      sig { params(name: String).returns(String) }
      def base_of(name)
        match = SLOT_NAME.match(name)
        match ? T.must(match[:base]) : name
      end
    end

    # @param base [String] slot 1's runner name
    # @param dir [String] slot 1's absolute install dir
    sig { params(base: String, dir: String).void }
    def initialize(base:, dir:)
      @base = base
      @dir = dir
    end

    # Whether a runner name is one of these slots.
    #
    # @param name [String]
    # @return [Boolean]
    sig { params(name: String).returns(T::Boolean) }
    def member?(name)
      !slot_of(name).nil?
    end

    # The slot a name denotes: 1 for `<base>`, n for `<base>-<n>`; nil for
    # a name that is none of these slots.
    #
    # @param name [String]
    # @return [Integer, nil]
    sig { params(name: String).returns(T.nilable(Integer)) }
    def slot_of(name)
      return 1 if name == @base

      match = SLOT_NAME.match(name)
      match && match[:base] == @base ? Integer(T.must(match[:slot])) : nil
    end

    # @param slot [Integer] 1-based
    # @return [String] the runner's GitHub-side name
    sig { params(slot: Integer).returns(String) }
    def slot_name(slot)
      slot == 1 ? @base : "#{@base}-#{slot}"
    end

    # @param slot [Integer] 1-based
    # @return [String] the absolute install dir
    sig { params(slot: Integer).returns(String) }
    def slot_dir(slot)
      slot == 1 ? @dir : "#{@dir}-#{slot}"
    end
  end
end
