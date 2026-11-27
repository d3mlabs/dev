# typed: false
# frozen_string_literal: true

# Real Process::Status values for the classes that read one. A shell
# adapter's `success?` / `exitstatus` branch is the behaviour under test,
# so the status is a real one, not a double answering `success?`. Ruby has
# no constructor for Process::Status; the one way to a value is a child
# that exited with the code, so the helper runs the cheapest one.
module ExitStatuses
  # @param code [Integer] the exit code the status reports
  # @return [Process::Status]
  def exit_status(code)
    _pid, status = Process.wait2(Process.spawn("sh", "-c", "exit #{Integer(code)}"))
    status
  end
end
