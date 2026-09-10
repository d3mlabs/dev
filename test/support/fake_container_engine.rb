# typed: false
# frozen_string_literal: true

require "dev/container_engine"

# A recording ContainerEngine for tests: the docker CLI is a true boundary,
# so tests fake the engine (argv in, scripted result out) instead of stubbing
# Kernel#system. A real ContainerEngine subclass so typed seams accept it.
#
#   engine = FakeContainerEngine.new { |args| args.first != "pull" }
#   engine.runs      # => every run's docker args (after the prefix)
#   engine.captures  # => every capture's docker args
class FakeContainerEngine < Dev::ContainerEngine
  attr_reader :runs, :run_envs, :captures

  # @param local_mounts [Boolean] what #local_mounts? answers
  # @param capture_result [String, Proc] stdout for capture calls (a proc
  #   receives the args and returns the stdout for that call)
  # @param run_handler [Proc, nil] decides each run's boolean result from its
  #   args; defaults to always succeeding
  def initialize(local_mounts: true, capture_result: "", &run_handler)
    super(kind: :fake)
    @local_mounts = local_mounts
    @capture_result = capture_result
    @run_handler = run_handler || ->(_args) { true }
    @runs = []
    @run_envs = []
    @captures = []
  end

  def run(args, env: {}, **_opts)
    @runs << args
    @run_envs << env
    !!@run_handler.call(args)
  end

  def capture(args, env: {})
    @captures << args
    @capture_result.respond_to?(:call) ? @capture_result.call(args) : @capture_result
  end

  def local_mounts?
    @local_mounts
  end
end
