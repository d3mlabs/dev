# typed: strict
# frozen_string_literal: true

require_relative "build_container_config"
require_relative "runner_setup_config"

module Dev
  # Context passed to Command#execute. Generic runtime context —
  # individual command types use what they need.
  class ExecutionContext < T::Struct
    extend T::Sig

    const :ui, Dev::Cli::Ui
    const :ruby_version, String
    const :python_version, T.nilable(String), default: nil
    const :project_root, Pathname
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    const :runner, T.nilable(Dev::RunnerSetupConfig), default: nil

    # When true, exec-style commands run spawn-and-wait (CommandRunner wait
    # mode) instead of exec-replacing the dev process, so the caller can
    # sequence post-execute work such as the installed stamp (#85).
    const :wait, T::Boolean, default: false
  end
end
