# typed: false
# frozen_string_literal: true

require "dev/deps/toolchain_exec"

# A ToolchainExec that records every capture3 and answers with a real
# child's status: `true`'s by default, `false`'s when told to fail. An
# optional effect runs on each call with the argv and env — what the
# real toolchain would have left on disk (a `vendor/bundle`).
class RecordingToolchainExec
  include Dev::Deps::ToolchainExec

  attr_reader :calls

  # @param fail [Boolean] whether every call exits non-zero
  # @param effect [Proc, nil] called with (argv, env) on each capture3
  def initialize(fail: false, effect: nil)
    @fail = fail
    @effect = effect
    @calls = []
  end

  def capture3(*command, env: {})
    @calls << [command, env]
    @effect&.call(command, env)
    _pid, status = Process.wait2(Process.spawn(@fail ? "false" : "true"))
    ["", @fail ? "bundler: could not find compatible versions" : "", status]
  end
end unless defined?(RecordingToolchainExec)
