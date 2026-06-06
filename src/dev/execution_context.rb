# typed: strict
# frozen_string_literal: true

module Dev
  # Context passed to Command#execute. Provides access to the command runner
  # (for shell commands) and project root (for built-in commands).
  class ExecutionContext < T::Struct
    extend T::Sig

    const :command_runner, T.untyped
    const :project_root, T.nilable(Pathname), default: nil
  end
end
