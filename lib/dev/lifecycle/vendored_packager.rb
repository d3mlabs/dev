# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/deps/self_contained_tree"
require "dev/deps/toolchain_exec"
require_relative "acceptance"
require_relative "packager"
require_relative "packager_spec"
require_relative "packed_archive"
# Build appears in a signature only; see packager.rb for why build.rb is
# not required here.

module Dev
  module Lifecycle
    # The `vendor: true` form of a packager: the stage is a self-contained
    # tree (Deps::SelfContainedTree), and its gems are vendored into it — a
    # frozen `bundle install` under the project's Ruby — before the wrapped
    # packager archives it. The asset then ships the vendored gems, and
    # dev's install of the tree writes launchers only. Vendoring is
    # redistribution and binds the asset to a platform unless every gem is
    # pure Ruby; the producer chose it.
    class VendoredPackager
      extend T::Sig
      include Packager

      # The stage carries no `dependencies.rb` and `deps.lock`: it is not
      # self-contained, so `vendor: true` names nothing to vendor.
      class NotSelfContainedError < RuntimeError
        extend T::Sig

        # @param stage [Pathname]
        sig { params(stage: Pathname).void }
        def initialize(stage:)
          super("vendor: #{stage} carries no #{Deps::Integration::MANIFEST_FILE} and #{Deps::Lockfile::DEPS_LOCK_FILE} — " \
            "a vendored archive is of a self-contained tree with its own lock")
        end
      end

      # @param packager [Packager] what archives the stage once vendored
      # @param exec [Deps::ToolchainExec] the project's Ruby, which the gems
      #   are installed under — the one the tree's own lock pins, in the
      #   checkout that releases it
      sig { params(packager: Packager, exec: Deps::ToolchainExec).void }
      def initialize(packager:, exec:)
        @packager = packager
        @exec = exec
      end

      # @param build [Build]
      # @param stage [Pathname] the self-contained tree the builder wrote
      # @param archive [Pathname] the path without extension
      # @param acceptance [Acceptance] handed to the wrapped packager, which presents the vendored tree
      # @return [PackedArchive]
      # @raise [NotSelfContainedError]
      # @raise [Deps::SelfContainedTree::GemBundle::VendorError]
      sig { override.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional)
        raise NotSelfContainedError.new(stage:) unless Deps::SelfContainedTree.carried_by?(stage)

        Deps::SelfContainedTree.new(root: stage).gem_bundle.vendor!(exec: @exec)
        @packager.package(build, stage, archive, acceptance:)
      end

      # The wrapped packager's: vendoring deprecates nothing of its own.
      sig { override.returns(T::Array[String]) }
      def deprecations
        @packager.deprecations
      end

      # The declaration as `dev help` renders it: the wrapped packager's,
      # then the vendoring.
      sig { returns(String) }
      def to_s
        "#{@packager}#{PackagerSpec::Archive::VENDORED}"
      end
    end
  end
end
