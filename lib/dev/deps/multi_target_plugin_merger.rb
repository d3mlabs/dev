# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "dev/lifecycle/byte_size"
require "dev/lifecycle/shell"
require_relative "alpakit_plugin"
require_relative "ficsit_target"
require_relative "multi_target_plugin"

module Dev
  module Deps
    # Merges per-target Alpakit zips into SMR's multi-target zip, inside
    # the ficsit publisher. Each archive is unpacked and read as an
    # AlpakitPlugin, then laid out under its target's directory; the layout
    # is zipped as `<ModRef>.zip`. Two archives may share a target (a Steam
    # and an Epic build are two Windows plugins whose binaries differ and
    # whose cooked content does not), and then their trees are unioned: a
    # file both carry must be byte-identical, since a publisher never
    # alters an archive's bytes. Everything is written under the channel's
    # scratch, wiped and rebuilt per merge; the archives are read, never
    # touched.
    # The shell is fixed for a process and so constructor-owned; the
    # archives are per call.
    class MultiTargetPluginMerger
      extend T::Sig

      # `merge` was handed no archive.
      class NothingToMergeError < ArgumentError; end

      # `unzip` could not unpack one of the archives.
      class UnpackFailedError < RuntimeError; end

      # `zip` could not write the merged archive.
      class PackFailedError < RuntimeError; end

      # The archives are plugins of different mods.
      class MixedModReferencesError < ArgumentError; end

      # The archives' `.uplugin` descriptors differ.
      class DifferingUpluginError < RuntimeError; end

      # Two archives of one target carry a file with different bytes.
      class ConflictingFileError < RuntimeError; end

      # The merged zip is over what SMR accepts.
      class PluginTooLargeError < RuntimeError; end

      # smr-api refuses an upload over 1 GB (`ExtractModInfo`: "mod archive
      # must be < 1GB", a decimal gigabyte).
      SMR_SIZE_LIMIT = T.let(Lifecycle::ByteSize.new(bytes: 1_000_000_000), Lifecycle::ByteSize)

      # Under the scratch: where the archives are unpacked and the layout
      # is built. Wiped at the start of every merge.
      WORK_DIR = "merge"
      UNPACKED_DIR = "unpacked"
      ZIP_EXTENSION = ".zip"

      # @param shell [Lifecycle::Shell] runs `unzip` and `zip`
      # @param size_limit [Lifecycle::ByteSize] what the merged zip may weigh (SMR's limit; tests lower it)
      sig { params(shell: Lifecycle::Shell, size_limit: Lifecycle::ByteSize).void }
      def initialize(shell: Lifecycle::Shell.new, size_limit: SMR_SIZE_LIMIT)
        @shell = shell
        @size_limit = size_limit
      end

      # Merge per-target zips into one multi-target zip at
      # `<scratch>/<ModRef>.zip`.
      #
      # @param archives [Array<Pathname>] the per-target zips, in shipment order; read only
      # @param scratch [Pathname] the channel's scratch; created if absent
      # @return [MultiTargetPlugin]
      # @raise [NothingToMergeError]
      # @raise [UnpackFailedError]
      # @raise [AlpakitPlugin::NotAPluginError] and the reader's other errors, for an archive that is not a per-target Alpakit zip
      # @raise [MixedModReferencesError]
      # @raise [DifferingUpluginError]
      # @raise [ConflictingFileError]
      # @raise [PackFailedError]
      # @raise [PluginTooLargeError]
      # @raise [Lifecycle::Shell::SpawnError] when `unzip` or `zip` is missing
      sig { params(archives: T::Array[Pathname], scratch: Pathname).returns(MultiTargetPlugin) }
      def merge(archives, scratch:)
        raise NothingToMergeError, "no archive to merge into a multi-target plugin" if archives.empty?

        workdir = scratch / WORK_DIR
        FileUtils.rm_rf(workdir)
        plugins = archives.each_with_index.map { |archive, index| unpack(archive, workdir / UNPACKED_DIR / "#{index}-#{archive.basename(ZIP_EXTENSION)}") }
        mod_reference = one_mod_reference(plugins)
        check_one_uplugin(plugins)

        layout = workdir / mod_reference
        lay_out(plugins, layout)
        zip = scratch / "#{mod_reference}#{ZIP_EXTENSION}"
        pack(layout, zip)
        check_size(zip, mod_reference)
        MultiTargetPlugin.new(archive: zip, mod_reference:, targets: plugins.map { |plugin, _archive| plugin.target }.uniq)
      end

      private

      # One archive, unpacked and read; the plugin is paired with the
      # archive it came from, for the messages.
      #
      # @param archive [Pathname]
      # @param into [Pathname]
      # @return [Array(AlpakitPlugin, Pathname)]
      # @raise [UnpackFailedError]
      sig { params(archive: Pathname, into: Pathname).returns([AlpakitPlugin, Pathname]) }
      def unpack(archive, into)
        into.mkpath
        status = @shell.run(["unzip", "-q", "-o", archive.to_s, "-d", into.to_s], chdir: into)
        raise UnpackFailedError, "unzip #{Lifecycle::Shell.describe(status)} unpacking #{archive}" unless status.success?

        [AlpakitPlugin.read(into), archive]
      end

      # The mod reference every plugin agrees on.
      #
      # @param plugins [Array<Array(AlpakitPlugin, Pathname)>]
      # @return [String]
      # @raise [MixedModReferencesError]
      sig { params(plugins: T::Array[[AlpakitPlugin, Pathname]]).returns(String) }
      def one_mod_reference(plugins)
        references = plugins.map { |plugin, _archive| plugin.mod_reference }.uniq
        return T.must(references.first) if references.size == 1

        described = plugins.map { |plugin, archive| "#{archive.basename} is #{plugin.mod_reference}" }.join(", ")
        raise MixedModReferencesError, "the archives are plugins of different mods (#{described}) — one deploy ships one mod"
      end

      # SMR reads one version from the zip and so takes one descriptor:
      # `validateMultiTargetPlugin` refuses "different .uplugin files"
      # across targets. Checked here so the refusal comes before the upload.
      #
      # @param plugins [Array<Array(AlpakitPlugin, Pathname)>]
      # @raise [DifferingUpluginError]
      sig { params(plugins: T::Array[[AlpakitPlugin, Pathname]]).void }
      def check_one_uplugin(plugins)
        first_plugin, first_archive = T.must(plugins.first)
        plugins.each do |plugin, archive|
          next if FileUtils.compare_file(first_plugin.uplugin, plugin.uplugin)

          raise DifferingUpluginError,
            "#{plugin.uplugin.basename} differs between #{first_archive.basename} and #{archive.basename} — " \
              "ficsit.app takes one descriptor per version, so every target must be staged from the same plugin source"
        end
      end

      # Copy every plugin's files under its target's directory, unioning
      # the plugins that share a target.
      #
      # @param plugins [Array<Array(AlpakitPlugin, Pathname)>]
      # @param layout [Pathname] the directory that becomes the zip's root
      # @raise [ConflictingFileError]
      sig { params(plugins: T::Array[[AlpakitPlugin, Pathname]], layout: Pathname).void }
      def lay_out(plugins, layout)
        placed = T.let({}, T::Hash[Pathname, Pathname])
        plugins.each do |plugin, archive|
          target_dir = layout / plugin.target.to_s
          plugin.files.each do |relative|
            source = plugin.dir / relative
            destination = target_dir / relative
            if destination.exist?
              next if FileUtils.compare_file(source, destination)

              raise ConflictingFileError,
                "#{plugin.target}/#{relative} differs between #{placed.fetch(destination).basename} and #{archive.basename} — " \
                  "SMR takes one #{plugin.target} tree per version, so builds sharing a target must stage identical files"
            end

            destination.dirname.mkpath
            FileUtils.cp(source, destination)
            placed[destination] = archive
          end
        end
      end

      # Zip the layout's contents as the multi-target archive, replacing a
      # previous merge's.
      #
      # @param layout [Pathname]
      # @param zip [Pathname]
      # @raise [PackFailedError]
      sig { params(layout: Pathname, zip: Pathname).void }
      def pack(layout, zip)
        FileUtils.rm_f(zip)
        status = @shell.run(["zip", "-r", "-q", "-y", zip.to_s, "."], chdir: layout)
        raise PackFailedError, "zip #{Lifecycle::Shell.describe(status)} writing #{zip}" unless status.success?
      end

      # @param zip [Pathname]
      # @param mod_reference [String]
      # @raise [PluginTooLargeError]
      sig { params(zip: Pathname, mod_reference: String).void }
      def check_size(zip, mod_reference)
        return if zip.size < @size_limit.bytes

        raise PluginTooLargeError,
          "#{mod_reference}'s multi-target zip is #{zip.size} bytes; ficsit.app takes less than #{@size_limit.bytes} — " \
            "ship fewer targets per deploy, or slim the cooked content"
      end
    end
  end
end
