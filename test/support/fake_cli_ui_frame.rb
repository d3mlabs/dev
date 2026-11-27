# typed: false
# frozen_string_literal: true

require "cli/ui"

# A CLI::UI::Frame (the class, as UiImpl is given it) that draws nothing:
# `open` runs the block and answers what it answered, raising what it
# raised, as cli-ui's does, and remembers each title and `timing:` it was
# opened with. The double for a frame protocol, which wraps the caller's
# work in a block — a mock never yields.
class FakeCliUiFrame
  Opening = Data.define(:title, :timing)

  attr_reader :openings

  def initialize
    @openings = []
  end

  def is_a?(klass)
    klass == CLI::UI::Frame.singleton_class || super
  end
  alias kind_of? is_a?

  # @param title [String]
  # @param timing [Boolean] whether the frame's close would print its elapsed time
  # @return [Object] what the block answered
  def open(title, timing: false)
    @openings << Opening.new(title:, timing:)
    yield
  end

  # @return [Array<String>] the titles opened, in order
  def titles
    @openings.map(&:title)
  end
end
