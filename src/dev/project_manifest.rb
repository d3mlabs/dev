# typed: strict
# frozen_string_literal: true

require_relative "build_container_config"
require_relative "command"

module Dev
  # The whole project declaration, coerced once at the boundary: the dev.yml
  # side (name, commands, build container) and the dependencies.rb side
  # (declared ruby/python toolchain versions). Immutable —
  # ProjectManifestLoader is the only writer, and it loads each source file
  # exactly once.
  class ProjectManifest < T::Struct
    extend T::Sig

    const :name, String
    const :commands, T::Hash[String, ProjectCommand]
    const :build_container, T.nilable(Dev::BuildContainerConfig), default: nil

    # The `ruby` / `python` directives from dependencies.rb, nil until the
    # loader's toolchain pass runs (or when nothing is declared — resolution
    # then falls back, e.g. to Homebrew Ruby).
    const :declared_ruby_version, T.nilable(String), default: nil
    const :declared_python_version, T.nilable(String), default: nil

    # The canonical machine-readable project id: the manifest name,
    # normalized. `name` is the project's package identity (the ecosystem
    # norm — gemspec/package.json/Cargo `name`; the org is the registry
    # giving it uniqueness), and the slug is its label/dir-safe form —
    # "Cellbound3D" → "cellbound3d". `dev runner register` derives the
    # repo runner label from it.
    #
    # @return [String]
    sig { returns(String) }
    def slug
      self.class.slug(name)
    end

    class << self
      extend T::Sig

      # #slug's derivation, callable on a bare name (e.g. from a
      # ProjectContext, which carries the name but not the manifest).
      #
      # @param name [String]
      # @return [String]
      sig { params(name: String).returns(String) }
      def slug(name)
        name.downcase.gsub(/[^a-z0-9]/, "")
      end
    end
  end
end
