# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  # Who has the terminal on this thread. A spinner, while it animates,
  # captures every Ruby-level write and masks stdin (CLI::UI's
  # StdoutRouter::Capture); a child spawned with inherited stdio writes
  # to fd 1 and reads fd 0 directly, past both. The two cannot share the
  # terminal: the child's lines garble the animation, and a child that
  # prompts waits on a stdin nobody can see it asking for — the shape of
  # every "dev hung under a spinner" we have had (plans#52).
  #
  # So the rule is structural rather than reviewed: the UI's `spin` marks
  # the thread's terminal as the spinner's for the block, and the places
  # dev spawns with inherited stdio (Lifecycle::Shell, Gh#stream) claim
  # the terminal first and are refused under a spinner. Thread-local:
  # a spinner's own worker threads are not the operator's terminal.
  module TerminalOwner
    extend T::Sig

    # Something that needs the terminal was asked for under a spinner —
    # the author wanted `ui.step`, not `ui.spin`.
    class UnderSpinnerError < RuntimeError; end

    KEY = :dev_terminal_owner_spinning

    class << self
      extend T::Sig

      # Whether a spinner has this thread's terminal right now.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def spinning? = Thread.current[KEY] == true

      # The terminal is the spinner's for the block.
      #
      # @yieldreturn the block's value, answered
      # @raise [UnderSpinnerError] a spinner is already running
      sig { type_parameters(:T).params(block: T.proc.returns(T.type_parameter(:T))).returns(T.type_parameter(:T)) }
      def spinning(&block)
        claim!("a spinner")
        Thread.current[KEY] = true
        begin
          block.call
        ensure
          Thread.current[KEY] = false
        end
      end

      # Something is about to take the terminal: a child with inherited
      # stdio, a prompt, a frame. Passes when the terminal is free.
      #
      # @param claimant [String] what wants it, for the refusal
      # @return [void]
      # @raise [UnderSpinnerError]
      sig { params(claimant: String).void }
      def claim!(claimant)
        return unless spinning?

        raise UnderSpinnerError,
          "#{claimant} would take the terminal under a spinner — a spinner captures stdout and masks stdin, " \
            "so its lines garble and its prompt hangs unseen; run it under `ui.step`, never `ui.spin`"
      end
    end
  end
end
