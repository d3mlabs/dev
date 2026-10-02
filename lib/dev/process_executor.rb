# typed: strict
# frozen_string_literal: true

require "open3"

module Dev
  # The process boundary the engine provisioners share. Same split as
  # HostService::BrewExecutor: `run` streams output to the terminal (a VM
  # start or a sudo prompt the user should see), `quiet?` only answers
  # success, `capture` returns stdout (inspection probes). Injectable so tests
  # never spawn the real thing.
  class ProcessExecutor
    extend T::Sig

    # @param cmd [Array<String>] argv, never a shell string
    # @return [Boolean]
    sig { params(cmd: String).returns(T::Boolean) }
    def run(*cmd)
      !!T.unsafe(Kernel).system(*cmd)
    end

    # @param cmd [Array<String>] argv, never a shell string
    # @return [Boolean]
    sig { params(cmd: String).returns(T::Boolean) }
    def quiet?(*cmd)
      _out, _err, status = T.unsafe(Open3).capture3(*cmd)
      status.success?
    rescue SystemCallError
      false
    end

    # @param cmd [Array<String>] argv, never a shell string
    # @return [String] stdout on success, "" otherwise
    sig { params(cmd: String).returns(String) }
    def capture(*cmd)
      out, _err, status = T.unsafe(Open3).capture3(*cmd)
      status.success? ? out : ""
    rescue SystemCallError
      ""
    end
  end
end
