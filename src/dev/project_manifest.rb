# typed: strict
# frozen_string_literal: true

require_relative "build_container_config"
require_relative "command"
require_relative "runner_setup_config"

module Dev
  # The whole project declaration, coerced once at the boundary: the dev.yml
  # side (name, commands, build container, runner identity) and the
  # dependencies.rb side (declared ruby/python toolchain versions).
  # Immutable — ProjectManifestLoader is the only writer, and it loads each
  # source file exactly once.
  class ProjectManifest < T::Struct
    extend T::Sig

    const :name, String
    const :commands, T::Hash[String, ProjectCommand]
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    const :runner, T.nilable(Dev::RunnerSetupConfig), default: nil

    # The `ruby` / `python` directives from dependencies.rb, nil until the
    # loader's toolchain pass runs (or when nothing is declared — resolution
    # then falls back, e.g. to Homebrew Ruby).
    const :declared_ruby_version, T.nilable(String), default: nil
    const :declared_python_version, T.nilable(String), default: nil
  end
end
