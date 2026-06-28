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
    const :project_root, Pathname
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    const :runner, T.nilable(Dev::RunnerSetupConfig), default: nil
  end
end
