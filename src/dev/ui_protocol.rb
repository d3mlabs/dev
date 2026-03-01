# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/ui"

module Dev
  # Parses a line-based protocol from child process output and renders it
  # via the Ui interface. Non-marker lines pass through as-is.
  #
  # Protocol markers (each must be a complete line):
  #   ::frame::Title       open a frame
  #   ::endframe::         close the current frame
  #   ::ok::label          green checkmark + label
  #   ::fail::label        red X + label
  #   ::warn::message      yellow warning
  #   ::spin::label        drain lines until ::endspin::, then report ok/fail
  #   ::endspin::          end spin with success (ok)
  #   ::endspin::fail      end spin with failure (fail)
  class UiProtocol
    extend T::Sig

    FRAME_RE    = T.let(/\A::frame::(.+)\z/, Regexp)
    ENDFRAME_RE = T.let(/\A::endframe::\z/, Regexp)
    OK_RE       = T.let(/\A::ok::(.+)\z/, Regexp)
    FAIL_RE     = T.let(/\A::fail::(.+)\z/, Regexp)
    WARN_RE     = T.let(/\A::warn::(.+)\z/, Regexp)
    SPIN_RE     = T.let(/\A::spin::(.+)\z/, Regexp)

    sig { params(ui: Dev::Cli::Ui).void }
    def initialize(ui:)
      @ui = T.let(ui, Dev::Cli::Ui)
      @frame_stack = T.let([], T::Array[String])
    end

    # Reads from +io+ line by line, dispatching protocol markers to the Ui
    # and passing plain lines through via print_line.
    sig { params(io: T.any(IO, StringIO)).void }
    def process_stream(io)
      io.each_line do |raw_line|
        line = raw_line.chomp
        next if dispatch_marker(line, io)

        @ui.print_line(raw_line.chomp("\n"))
      end
    rescue Errno::EIO
      # Expected when child exits and PTY slave closes
    end

    private

    sig { params(line: String, io: T.any(IO, StringIO)).returns(T::Boolean) }
    def dispatch_marker(line, io)
      case line
      when FRAME_RE
        title = T.must(Regexp.last_match(1))
        @frame_stack.push(title)
        @ui.open_frame(title)
      when ENDFRAME_RE
        title = @frame_stack.pop
        @ui.close_frame(title || "")
      when OK_RE
        @ui.ok(T.must(Regexp.last_match(1)))
      when FAIL_RE
        @ui.fail(T.must(Regexp.last_match(1)))
      when WARN_RE
        @ui.warn(T.must(Regexp.last_match(1)))
      when SPIN_RE
        drain_until_endspin(T.must(Regexp.last_match(1)), io)
      else
        return false
      end
      true
    end

    # Reads and discards lines from +io+ until ::endspin:: or ::endspin::fail,
    # then reports success/failure via ok/fail on the Ui.
    sig { params(label: String, io: T.any(IO, StringIO)).void }
    def drain_until_endspin(label, io)
      loop do
        raw = io.gets
        break if raw.nil?

        line = raw.chomp
        if line == "::endspin::"
          @ui.ok(label)
          return
        elsif line == "::endspin::fail"
          @ui.fail(label)
          return
        end
      end
      # EOF before ::endspin:: — treat as failure
      @ui.fail(label)
    end
  end
end
