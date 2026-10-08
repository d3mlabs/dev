# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "channel"
require_relative "installer"
require_relative "manifest"

module Dev
  module Skills
    # Places what channels declare into their roots and takes back what they
    # no longer declare. The one piece of dev that writes skill links:
    # producers hand it channels, it installs every entry, prunes the links
    # it recorded for the channel last time that the channel has stopped
    # declaring (the skill vanished from the corpus, the gem left the lock),
    # and rewrites the root's manifest. Prune is exact — previous manifest
    # minus next — so a link dev did not mint is never touched. Never raises:
    # skill links are hygiene riding another command, and hygiene must not
    # block correctness (failures are reported on stderr, per channel).
    class Materializer
      extend T::Sig

      # The self-ignore file a project-scoped root carries so the subtree is
      # never committed, even in a repo that never ran the scaffold.
      SELF_IGNORE = "*\n"

      # A link as status sees it: its manifest record and whether the link
      # on disk still matches it.
      class Materialized < T::Struct
        extend T::Sig

        const :record, Manifest::Record
        const :present, T::Boolean
      end

      InstallerFactory = T.type_alias { T.proc.params(root: Pathname).returns(Installer) }

      # @param installer_factory [Proc] builds the Installer for a root;
      #   injected so tests pin the temp-dir guard
      sig { params(installer_factory: InstallerFactory).void }
      def initialize(installer_factory: ->(root) { Installer.new(skills_dir: root) })
        @installer_factory = installer_factory
      end

      # Materialize every channel: install its entries, prune its stale
      # links, record it. Channels are independent — one failing is reported
      # and the rest still run.
      #
      # @param channels [Array<Dev::Skills::Channel>]
      # @return [void]
      sig { params(channels: T::Array[Channel]).void }
      def sync(channels)
        channels.each { |channel| materialize(channel) }
      end

      # The channel's links as recorded in its root's manifest, each checked
      # against the disk.
      #
      # @param channel [Dev::Skills::Channel]
      # @return [Array<Dev::Skills::Materializer::Materialized>] sorted by link
      sig { params(channel: Channel).returns(T::Array[Materialized]) }
      def materialized(channel)
        root = channel.root
        Manifest.read(root).for_integration(channel.name).map do |record|
          Materialized.new(record: record, present: present?(root, record))
        end
      end

      private

      # @param channel [Dev::Skills::Channel]
      # @return [void]
      sig { params(channel: Channel).void }
      def materialize(channel)
        root = channel.root
        installer = @installer_factory.call(root)
        entries = channel.entries
        entries.each { |entry| installer.install(entry.link_name, entry.source) }

        previous = Manifest.read(root)
        prune(previous, channel, installer, entries.map(&:link_name))
        self_ignore(root) if channel.project_scoped?
        previous.replacing(channel.name, records(root, channel, entries)).write
      rescue StandardError => e
        $stderr.puts "dev: warning: could not materialize #{channel.name} skills (#{e.message})."
      end

      # Remove the links recorded for the channel that it no longer declares.
      # An entry whose source is ephemeral is still *declared*, so the
      # durable link it shadows survives (the installer declined to re-point
      # it; this must not then delete it).
      #
      # @param previous [Dev::Skills::Manifest] the root's manifest from the last pass
      # @param channel [Dev::Skills::Channel]
      # @param installer [Dev::Skills::Installer]
      # @param expected [Array<String>] the link names the channel declares
      # @return [void]
      sig { params(previous: Manifest, channel: Channel, installer: Installer, expected: T::Array[String]).void }
      def prune(previous, channel, installer, expected)
        previous.for_integration(channel.name).each do |record|
          installer.remove(record.link) unless expected.include?(record.link)
        end
      end

      # What actually stands in the root for the channel after this pass: one
      # record per declared entry whose link exists, with the target the link
      # really has (an ephemeral source the installer refused leaves the
      # earlier durable target in place, and that is what gets recorded).
      #
      # @param root [Pathname]
      # @param channel [Dev::Skills::Channel]
      # @param entries [Array<Dev::Skills::Entry>]
      # @return [Array<Dev::Skills::Manifest::Record>]
      sig { params(root: Pathname, channel: Channel, entries: T::Array[Entry]).returns(T::Array[Manifest::Record]) }
      def records(root, channel, entries)
        entries.filter_map do |entry|
          link = root / entry.link_name
          next unless link.symlink?

          Manifest::Record.new(
            name: entry.name, integration: channel.name, link: entry.link_name,
            source: link.readlink.to_s, package: entry.package, version: entry.version,
          )
        end
      end

      # @param root [Pathname]
      # @param record [Dev::Skills::Manifest::Record]
      # @return [Boolean] whether the link exists and still points where recorded
      sig { params(root: Pathname, record: Manifest::Record).returns(T::Boolean) }
      def present?(root, record)
        link = record.link_path(root)
        link.symlink? && link.readlink.to_s == record.source
      end

      # Write the root's self-ignore file once; an existing file (dev's or a
      # user's) is left alone.
      #
      # @param root [Pathname]
      # @return [void]
      sig { params(root: Pathname).void }
      def self_ignore(root)
        file = root / ".gitignore"
        return if file.exist?

        root.mkpath
        file.write(SELF_IGNORE)
      end
    end
  end
end
