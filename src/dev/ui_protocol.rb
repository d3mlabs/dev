# typed: strict
# frozen_string_literal: true

require "stringio"
require "dev/cli/ui"

module Dev
  # Parses a line-based protocol from child process output and renders it
  # via the Ui interface. Non-marker lines are written directly to +raw_out+
  # (bypassing CLI::UI::StdoutRouter) so that child processes using CLI::UI
  # render correctly without double-decoration.
  #
  # Protocol markers (each must be a complete line):
  #   ::frame::Title       open a frame
  #   ::endframe::         close the current frame
  #   ::ok::label          green checkmark + label
  #   ::fail::label        red X + label
  #   ::warn::message      yellow warning
  #   ::spin::label        start animated spinner, drain lines until ::endspin::
  #   ::endspin::          end spin with success
  #   ::endspin::fail      end spin with failure
  class UiProtocol
    extend T::Sig

    FRAME_RE    = T.let(/\A::frame::(.+)\z/, Regexp)
    ENDFRAME_RE = T.let(/\A::endframe::\z/, Regexp)
    OK_RE       = T.let(/\A::ok::(.+)\z/, Regexp)
    FAIL_RE     = T.let(/\A::fail::(.+)\z/, Regexp)
    WARN_RE     = T.let(/\A::warn::(.+)\z/, Regexp)
    SPIN_RE     = T.let(/\A::spin::(.+)\z/, Regexp)

    # +raw_out+ bypasses StdoutRouter so child CLI::UI output reaches the
    # terminal untouched. In production this defaults to a raw fd handle;
    # tests inject a StringIO.
    sig { params(ui: Dev::Cli::Ui, raw_out: T.any(IO, StringIO)).void }
    def initialize(ui:, raw_out: T.unsafe(IO).for_fd($stdout.fileno, autoclose: false))
      @ui = T.let(ui, Dev::Cli::Ui)
      @raw_out = T.let(raw_out, T.any(IO, StringIO))
      @raw_out.sync = true if @raw_out.respond_to?(:sync=)
      @frame_stack = T.let([], T::Array[String])
    end

    # Reads from +io+ line by line, dispatching protocol markers to the Ui.
    # Non-marker lines inside a protocol frame go through @ui.print_line
    # (so they get frame borders from StdoutRouter). Non-marker lines
    # outside any frame go to @raw_out (bypass StdoutRouter, so CLI::UI
    # child output renders correctly).
    sig { params(io: T.any(IO, StringIO)).void }
    def process_stream(io)
      io.each_line do |raw_line|
        line = raw_line.chomp
        next if dispatch_marker(line, io)

        if @frame_stack.any?
          @ui.print_line(line)
        else
          @raw_out.write(raw_line)
        end
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

    # Wraps the drain loop in a spinner so the animation plays while the
    # child process runs. Returns success/failure via the spinner block's
    # return value (truthy = checkmark, falsy = X).
    sig { params(label: String, io: T.any(IO, StringIO)).void }
    def drain_until_endspin(label, io)
      T.unsafe(@ui).with_spinner(label) do
        success = T.let(false, T::Boolean)
        loop do
          raw = io.gets
          break if raw.nil?

          line = raw.chomp
          if line == "::endspin::"
            success = true
            break
          elsif line == "::endspin::fail"
            break
          end
        end
        success
      end
    end
  end
end
