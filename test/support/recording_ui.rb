# typed: false
# frozen_string_literal: true

require "dev/ui"
require "stringio"

# A Ui that remembers the frames it opened and the notes it was handed,
# as the caller spoke them — titles, nesting depth and the raw markup of
# each note, before any tier renders it. The double for a test about a
# report's *shape* (which facts sit under which section), where the
# plain tier's text would blur the structure (plans#52). Everything else
# is `NoUi`.
class RecordingUi < Dev::NoUi
  # One frame or note, in order. A frame's `text` is its title; `depth`
  # is how many frames were open around it (0 at the top).
  Event = Data.define(:kind, :text, :depth)

  attr_reader :events

  def initialize(out: StringIO.new)
    super(out:)
    @events = []
    @depth = 0
  end

  def frame(title, &block)
    @events << Event.new(kind: :frame, text: title, depth: @depth)
    @depth += 1
    super
  ensure
    @depth -= 1
  end

  def note(text)
    @events << Event.new(kind: :note, text: text, depth: @depth)
    super
  end

  # The events as `[kind, text, depth]` rows, for a table-shaped assertion.
  #
  # @return [Array<Array>]
  def rows = @events.map { |event| [event.kind, event.text, event.depth] }
end
