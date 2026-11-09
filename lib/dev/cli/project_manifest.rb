# typed: strict
# frozen_string_literal: true

require "dev/engine_resources"
require "dev/lifecycle"
require_relative "command"

module Dev
  module Cli
    # The project declaration as dev.yml states it (name, commands, targets,
    # engine sizing), coerced once at the boundary. Immutable —
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
      # What the project can build (`targets:`, dev#192), in declaration
      # order — the first is what bare `build` means. Empty when the project
      # declares none, and then no lifecycle verb exists for it.
      const :targets, T::Hash[String, Lifecycle::Target], default: {}
      # Where the project ships artifacts (`commands: deploy:`'s children,
      # dev#192 K5), in declaration order — lifted out of `commands` once
      # targets exist, since `deploy` is derived from them. Empty when the
      # project declares none, and then `deploy` does not exist for it.
      const :channels, T::Hash[String, Lifecycle::Channel], default: {}
      # What a release contains (`commands: release:`, dev#192 K4) — lifted
      # out of `commands` once targets exist, since `release` is derived
      # from them. Nil when the project declares none, and then `release`
      # does not exist for it.
      const :release, T.nilable(Lifecycle::ReleaseBuilds), default: nil
      # The engine floor this project's build was tuned for (`engine:`); nil
      # means the provisioner's defaults and no check.
      const :engine, T.nilable(Dev::EngineResources::Hint), default: nil
    end
  end
end
