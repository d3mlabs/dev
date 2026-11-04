# typed: strict
# frozen_string_literal: true

require "pathname"
# Build appears in a signature only; as for Packager, requiring build.rb
# here would close a load cycle through Target. `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the project's build tool for the `build`
    # verb (dev#192, K1): given a build, make its **install** — what the
    # toolchain calls done (UE's compiled, cooked and staged game; a
    # library's install tree; for a gem or an org payload, the laid-out
    # file set) — into the directory dev hands it. The builder never knows
    # the archive format: that is the Packager's, which is why a target
    # declares the two separately.
    #
    # Two forms: a script (ScriptBuilder — the target's `build:` line,
    # reading the build from `DEV_*`), and an integration owning the
    # toolchain mapping once (dev#433), which also declares the target
    # options it accepts through `target_options_schema`.
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
    end
  end
end
