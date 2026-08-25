# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build_container_config"
require_relative "cli/ui"
require_relative "runner_setup_config"

module Dev
  # The project half of an execution context: everything resolved from the
  # enclosing dev.yml project. Absent entirely when no project encloses the
  # cwd — commands that need it either only exist when it does (project
  # builtins, yaml commands) or handle its absence as their own business
  # logic (hybrids like `up`).
  class ProjectContext < T::Struct
    const :root, Pathname
    const :ruby_version, String
    const :python_version, T.nilable(String), default: nil
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    const :runner, T.nilable(Dev::RunnerSetupConfig), default: nil
  end

  # Context passed to a command execution: the host half (always present)
  # plus the project half (nil outside any dev.yml project). Individual
  # command types use what they need.
  class ExecutionContext < T::Struct
    extend T::Sig

    # `project!` was called with no project half. Project commands are
    # registered only when a project exists, so reaching this is a dev bug —
    # the raise makes the registration invariant explicit.
    class ProjectRequiredError < StandardError; end

    const :ui, Dev::Cli::Ui
    const :project, T.nilable(Dev::ProjectContext), default: nil

    # The project half, for commands that require a project.
    #
    # @return [Dev::ProjectContext]
    # @raise [ProjectRequiredError] when no project encloses the run
    sig { returns(Dev::ProjectContext) }
    def project!
      project || raise(ProjectRequiredError, "no project context — this command requires a dev.yml project")
    end
  end
end
