# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "channel"
require_relative "installer"

module Dev
  module Skills
    # Places what channels declare into their roots and takes back what they
    # no longer declare. The one piece of dev that writes skill links:
    # producers hand it channels, it installs every entry and prunes the
    # links each channel owns but has stopped declaring (the skill vanished
    # from the corpus, the gem left the lock). Never raises — skill links
    # are hygiene riding another command, and hygiene must not block
    # correctness (failures are reported on stderr, per channel).
    class Materializer
      extend T::Sig

      # A link on disk as status sees it: where it is, what it points at,
      # and the entry that declares it (nil for a link the channel owns but
      # no longer declares — visible between a producer change and the next
      # sync).
      class Materialized < T::Struct
        extend T::Sig

        const :link, Pathname
        const :target, Pathname
        const :entry, T.nilable(Entry), default: nil
      end

      InstallerFactory = T.type_alias { T.proc.params(root: Pathname).returns(Installer) }

      # @param installer_factory [Proc] builds the Installer for a root;
      #   injected so tests pin the temp-dir guard
      sig { params(installer_factory: InstallerFactory).void }
      def initialize(installer_factory: ->(root) { Installer.new(skills_dir: root) })
        @installer_factory = installer_factory
      end

      # Materialize every channel: install its entries, prune its stale
      # links. Channels are independent — one failing is reported and the
      # rest still run.
      #
      # @param channels [Array<Dev::Skills::Channel>]
      # @return [void]
      sig { params(channels: T::Array[Channel]).void }
      def sync(channels)
        channels.each { |channel| materialize(channel) }
      end

      # The channel's links as they stand on disk, declared or stale.
      #
      # @param channel [Dev::Skills::Channel]
      # @return [Array<Dev::Skills::Materializer::Materialized>] sorted by link name
      sig { params(channel: Channel).returns(T::Array[Materialized]) }
      def materialized(channel)
        by_name = channel.entries.to_h { |entry| [entry.link_name, entry] }
        owned_links(channel).map do |link|
          Materialized.new(link: link, target: link.readlink, entry: by_name[link.basename.to_s])
        end
      end

      private

      # @param channel [Dev::Skills::Channel]
      # @return [void]
      sig { params(channel: Channel).void }
      def materialize(channel)
        installer = @installer_factory.call(channel.root)
        entries = channel.entries
        entries.each { |entry| installer.install(entry.link_name, entry.source) }
        prune(channel, installer, entries.map(&:link_name))
      rescue StandardError => e
        $stderr.puts "dev: warning: could not materialize #{channel.name} skills (#{e.message})."
      end

      # Remove the links the channel owns but no longer declares. An entry
      # whose source is ephemeral is still *declared*, so the durable link it
      # shadows survives (the installer declined to re-point it; this must
      # not then delete it).
      #
      # @param channel [Dev::Skills::Channel]
      # @param installer [Dev::Skills::Installer]
      # @param expected [Array<String>] the link names the channel declares
      # @return [void]
      sig { params(channel: Channel, installer: Installer, expected: T::Array[String]).void }
      def prune(channel, installer, expected)
        owned_links(channel).each do |link|
          name = link.basename.to_s
          installer.remove(name) unless expected.include?(name)
        end
      end

      # The symlinks in the root that the channel claims, sorted.
      #
      # @param channel [Dev::Skills::Channel]
      # @return [Array<Pathname>]
      sig { params(channel: Channel).returns(T::Array[Pathname]) }
      def owned_links(channel)
        root = channel.root
        return [] unless root.directory?

        root.children.select { |link| link.symlink? && channel.owns?(link) }.sort
      end
    end
  end
end
