# typed: strict
# frozen_string_literal: true

require "pathname"
# Build appears in a signature only; as for Packager, requiring build.rb
# here would close a load cycle through Target. `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the project's build tool: given a build, make
    # its install into the directory dev hands it. The builder never knows
    # the archive format; that is the Packager's.
    #
    # ScriptBuilder is the target's `build:` line, reading the build from
    # `DEV_*`. An integration builder owns the toolchain mapping and declares
    # the target options it accepts through `target_options_schema`.
    module Builder
      extend T::Sig
      extend T::Helpers
      interface!

      # Make the build's install.
      #
      # @param build [Build] what to build
      # @param install [Pathname] the directory the install goes into
      #   (created if absent); what the Packager reads next
      # @return [void]
      sig { abstract.params(build: Build, install: Pathname).void }
      def build(build, install); end

      # The keys a target may carry for this builder, namespaced under its
      # name in dev.yml; validated by the builder, never defined by dev.
      # Empty for a script, which takes its parameters from the env.
      #
      # @return [Array<String>]
      sig { abstract.returns(T::Array[String]) }
      def target_options_schema; end

      # What `build-id.json` records as `builder`: `script` for the script
      # form, an integration's name for its own.
      #
      # @return [String]
      sig { abstract.returns(String) }
      def name; end

      # What `build-id.json` records as `builder_version`: an engine tag for
      # an integration that has one, nil for a script.
      #
      # @return [String, nil]
      sig { abstract.returns(T.nilable(String)) }
      def version; end
    end
  end
end
