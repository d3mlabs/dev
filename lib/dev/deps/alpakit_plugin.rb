# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "ficsit_target"

module Dev
  module Deps
    # A staged plugin as Alpakit zips it for one target
    # (`PackagePlugin.cs`: `<ModRef>-<cook platform>.zip` over the staged
    # plugin directory), read from the zip's unpacked tree. Two facts are
    # in the tree, and they are the two the ficsit publisher needs:
    #
    # - the **mod reference** — the one `<ModRef>.uplugin` at the root, the
    #   name SMR identifies the mod by (`getModByReference`) and checks
    #   every uploaded `.uplugin` against;
    # - the **target** — the one directory under `Content/Paks/`, where the
    #   cook left the plugin's paks: Unreal's cooked-platform name, which
    #   is SMR's target name (FicsitTarget).
    #
    # This is what a mod build's archive is under `packager: as-is`
    # (snappy's three targets), and the unit the publisher merges into
    # SMR's multi-target zip (MultiTargetPluginMerger). The tree is read,
    # never written.
    class AlpakitPlugin < T::Struct
      extend T::Sig

      # The tree has no `.uplugin` at its root, or more than one.
      class NotAPluginError < ArgumentError; end

      # The tree has no `Content/Paks/<target>/`: nothing says what it was
      # cooked for.
      class NoTargetError < ArgumentError; end

      # The tree has paks for more than one target.
      class SeveralTargetsError < ArgumentError; end

      UPLUGIN_EXTENSION = ".uplugin"
      PAKS_DIR = T.let(Pathname("Content/Paks"), Pathname)

      const :dir, Pathname
      const :mod_reference, String
      const :target, FicsitTarget

      class << self
        extend T::Sig

        # Read the plugin an unpacked per-target zip holds.
        #
        # @param dir [Pathname] the unpacked tree
        # @return [AlpakitPlugin]
        # @raise [NotAPluginError]
        # @raise [NoTargetError]
        # @raise [SeveralTargetsError]
        # @raise [UnknownFicsitTargetError] a paks directory SMR has no target for
        sig { params(dir: Pathname).returns(AlpakitPlugin) }
        def read(dir)
          uplugins = dir.children.select { |child| child.file? && child.extname == UPLUGIN_EXTENSION }
          unless uplugins.size == 1
            raise NotAPluginError,
              "#{dir} is not an Alpakit plugin: expected one <ModRef>#{UPLUGIN_EXTENSION} at its root, " \
                "found #{uplugins.empty? ? "none" : uplugins.map(&:basename).join(", ")}"
          end

          paks = dir / PAKS_DIR
          cook_platforms = paks.directory? ? paks.children.select(&:directory?).sort : []
          raise NoTargetError, "#{dir} has no #{PAKS_DIR}/<target>/ — nothing says what it was cooked for" if cook_platforms.empty?
          if cook_platforms.size > 1
            raise SeveralTargetsError,
              "#{dir} holds paks for #{cook_platforms.map(&:basename).join(", ")} — one Alpakit zip is one target"
          end

          new(
            dir:,
            mod_reference: T.must(uplugins.first).basename(UPLUGIN_EXTENSION).to_s,
            target: FicsitTarget.parse(T.must(cook_platforms.first).basename.to_s),
          )
        end
      end

      # The plugin's descriptor file.
      #
      # @return [Pathname]
      sig { returns(Pathname) }
      def uplugin = dir / "#{mod_reference}#{UPLUGIN_EXTENSION}"

      # Every file of the tree, relative to its root, in a stable order.
      #
      # @return [Array<Pathname>]
      sig { returns(T::Array[Pathname]) }
      def files
        dir.glob("**/*", File::FNM_DOTMATCH).select(&:file?).map { |file| file.relative_path_from(dir) }.sort
      end

      sig { returns(String) }
      def to_s = "#{mod_reference} (#{target})"
    end
  end
end
