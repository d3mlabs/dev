# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
# Build appears in a signature only; as for Packager, requiring build.rb
# here would close a load cycle through Target. `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the project's build tool: given a build, make
    # its stage — the runnable, laid-out output — in the directory dev
    # hands it. The builder never knows the archive format; that is the
    # Packager's.
    #
    # The stage is fresh before any implementation runs: `build` empties
    # the directory and recreates it, then asks the implementation to fill
    # it. One rule, in dev, so no script has to clear a previous build's
    # files itself; a toolchain's incremental state lives in its own build
    # directory, never in the stage, so nothing is lost.
    #
    # ScriptBuilder is the target's `builder:` script, reading the build from
    # `DEV_*`; CheckoutBuilder is the identity element a target with no
    # `builder:` gets — the checkout's tracked files. An integration builder
    # owns the toolchain mapping and declares the target options it accepts
    # through `target_options_schema`.
    module Builder
      extend T::Sig
      extend T::Helpers
      abstract!

      # Make the build's stage: emptied, then filled.
      #
      # @param build [Build] what to build
      # @param stage [Pathname] the directory the stage goes into; emptied
      #   and recreated here, then what the Packager reads next
      # @return [void]
      sig(:final) { params(build: Build, stage: Pathname).void }
      def build(build, stage)
        FileUtils.rm_rf(stage)
        stage.mkpath
        fill(build, stage)
      end

      # Fill the fresh stage with the build's output.
      #
      # @param build [Build] what to build
      # @param stage [Pathname] exists and is empty
      # @return [void]
      sig { abstract.params(build: Build, stage: Pathname).void }
      def fill(build, stage); end

      # The keys a target may carry for this builder, namespaced under its
      # name in dev.yml; validated by the builder, never defined by dev.
      # Empty for a script, which takes its parameters from the env.
      #
      # @return [Array<String>]
      sig { abstract.returns(T::Array[String]) }
      def target_options_schema; end

      # What `build-id.json` records as `builder`: `script` for the script
      # form, `checkout` for the identity builder, an integration's name
      # for its own.
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

      # What the verb tells the operator after this builder ran: each line
      # names something the declaration relies on that the next release
      # drops, and what to change. Nothing, for most builders.
      #
      # @return [Array<String>]
      sig { overridable.returns(T::Array[String]) }
      def deprecations
        []
      end
    end
  end
end
