# typed: false
# frozen_string_literal: true

# Records every host invocation the agent host bootstrap makes; the admin
# CLIs (sysadminctl, dseditgroup, useradd, visudo, systemctl, ...) are a
# true boundary — tests never mutate the host. Probes (`quiet?`) and
# captures answer from canned tables, defaulting to "not there".
class RecordedBootstrapExecutor
  attr_reader :runs, :probes

  # @param probe_results [Hash{Array<String> => Boolean}] quiet? answers (default false)
  # @param capture_results [Hash{Array<String> => String}] capture answers (default "")
  # @param fail_matching [String, nil] run() fails when the argv mentions this token
  def initialize(probe_results: {}, capture_results: {}, fail_matching: nil)
    @probe_results = probe_results
    @capture_results = capture_results
    @fail_matching = fail_matching
    @runs = []
    @probes = []
  end

  def run(*cmd, chdir: nil)
    @runs << (chdir ? cmd + [{ chdir: chdir }] : cmd)
    return false if @fail_matching && cmd.any? { |arg| arg.include?(@fail_matching) }

    true
  end

  def quiet?(*cmd)
    @probes << cmd
    @probe_results.fetch(cmd, false)
  end

  def capture(*cmd)
    @capture_results.fetch(cmd, "")
  end
end
