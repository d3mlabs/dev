# typed: strict
# frozen_string_literal: true

require_relative "build_container_config"
require_relative "command"

module Dev
  # The project declaration as dev.yml states it (name, commands, build
  # container), coerced once at the boundary. Immutable —
  # ProjectManifestLoader is the only writer, and it reads the file exactly
  # once. The toolchain is not here: `ruby` / `python` are dependencies
  # declared in dependencies.rb, which only the deps commands read.
  class ProjectManifest < T::Struct
    extend T::Sig

    # The project's package identity (the ecosystem norm — gemspec /
    # package.json / Cargo `name`); not its repo name, which `dev runner
    # register` reads from GitHub.
    const :name, String
    # The project's command tree as declared: runnable commands (with any
    # nested `commands:` as children) and groups.
    const :commands, T::Hash[String, ProjectNode]
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
  end
end
