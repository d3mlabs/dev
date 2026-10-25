# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build_container_config"
require_relative "cli/ui"
require "dev/engine_resources"
require_relative "project_images"

module Dev
  # The project half of an execution context: everything resolved from the
  # enclosing dev.yml project. Absent entirely when no project encloses the
  # cwd — commands that need it either only exist when it does (project
  # builtins, yaml commands) or handle its absence as their own business
  # logic (hybrids like `up`).
  class ProjectContext < T::Struct
    extend T::Sig

    # The manifest-declared project name — the package identity (see
    # ProjectManifest#name).
    const :name, String
    const :root, Pathname
    # The engine floor the project declares (ProjectManifest#engine).
    const :engine, T.nilable(Dev::EngineResources::Hint), default: nil
    # Deprecated (d3mlabs/dev#311): the `build.container` block.
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    # The retired dev.yml keys the project still carries (ProjectManifest#legacy_keys).
    const :legacy_keys, T::Array[String], default: []

    # The project's environment images and where each command runs
    # (ProjectImages). One instance per context: the lock is read once.
    #
    # @return [Dev::ProjectImages]
    sig { returns(Dev::ProjectImages) }
    def project_images
      @project_images ||= T.let(
        Dev::ProjectImages.new(root: root, build_container: build_container, legacy_keys: legacy_keys, engine: engine),
        T.nilable(Dev::ProjectImages),
      )
    end
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
