# typed: false
# frozen_string_literal: true

require "cli/ui"

# A CLI::UI::Spinner (the class, as UiImpl is given it) that spins nothing:
# `spin` runs the block and answers as cli-ui's does — true when it
# returned, false when it raised, the raise swallowed — and remembers each
# title and `auto_debrief:` it was asked to spin. A refusing spinner is
# cli-ui's with the StdoutRouter off: it answers false without running the
# block at all. The double for a spinner protocol, which wraps the caller's
# work in a block — a mock never yields.
class FakeCliUiSpinner
  Spin = Data.define(:title, :auto_debrief)

  attr_reader :spins

  # @param refuses_block [Boolean] whether `spin` answers false without running the block
  def initialize(refuses_block: false)
    @refuses_block = refuses_block
    @spins = []
  end

  def is_a?(klass)
    klass == CLI::UI::Spinner.singleton_class || super
  end
  alias kind_of? is_a?

  # @param title [String]
  # @param auto_debrief [Boolean] whether cli-ui would print a failed block's backtrace
  # @return [Boolean] whether the block ran to its end
  def spin(title, auto_debrief: true)
    @spins << Spin.new(title:, auto_debrief:)
    return false if @refuses_block

    yield
    true
  rescue StandardError
    false
  end

  # @return [Array<String>] the titles spun, in order
  def titles
    @spins.map(&:title)
  end
end
