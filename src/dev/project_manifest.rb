# typed: strict
# frozen_string_literal: true

require "dev/engine_resources"
require_relative "build_container_config"
require_relative "command"

module Dev
  # The project declaration as dev.yml states it (name, commands, engine
  # sizing, build container), coerced once at the boundary. Immutable —
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
    # The engine floor this project's build was tuned for (`engine:`); nil
    # means the provisioner's defaults and no check.
    const :engine, T.nilable(Dev::EngineResources::Hint), default: nil
    # Deprecated (d3mlabs/dev#311): the `build.container` block.
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil
    # The retired keys dev.yml still carries, as dev.yml paths
    # (`build.container`, `commands.deploy.container: false`), in document
    # order.
    # Accepted while the project is on the legacy path; refused with their
    # migrations the moment its lock pins an image (ProjectImages).
    const :legacy_keys, T::Array[String], default: []
  end
end
