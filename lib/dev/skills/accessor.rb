# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require_relative "channel"
require_relative "materializer"

module Dev
  module Skills
    # Dispatch for `dev skills …` — the explicit surface over skill
    # materialization. Passive materialization rides dev's hook points
    # (`dev up` / `dev deps install` / `dev plan`); these verbs are the
    # manual override and the inspection, across every channel at once:
    #
    # - `status` — per channel: where its links land and what is linked,
    #              with the package and version a link came from when the
    #              channel knows them (gem skills)
    # - `sync`   — re-materialize every channel from what its producer
    #              declares right now (no cache refresh — that is `dev
    #              learnings sync`'s)
    #
    # The channels are composed by the caller (HostService knows which
    # producers exist on this machine for a project); this class only knows
    # how to show and sync a list of them.
    class Accessor
      extend T::Sig

      class UsageError < RuntimeError; end

      # @param channels [Array<Dev::Skills::Channel>] every channel to report
      #   or materialize, in display order
      # @param materializer [Dev::Skills::Materializer]
      sig { params(channels: T::Array[Channel], materializer: Materializer).void }
      def initialize(channels:, materializer: Materializer.new)
        @channels = channels
        @materializer = materializer
      end

      # `dev skills status`: each channel's root and its materialized links.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def status(out:)
        @channels.each do |channel|
          links = @materializer.materialized(channel)
          out.puts "dev: #{channel.name} skills: #{links.size} linked under #{channel.root}"
          links.each { |link| out.puts "  #{describe(link)}" }
        end
      end

      # `dev skills sync`: materialize every channel now.
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def sync(out:)
        @materializer.sync(@channels)
        @channels.each do |channel|
          out.puts "dev: #{channel.name} skills: #{channel.entries.size} materialized under #{channel.root}."
        end
      end

      private

      # One status line: the link name, its provenance when known, and the
      # target; a link the channel owns but no longer declares is flagged.
      #
      # @param link [Dev::Skills::Materializer::Materialized]
      # @return [String]
      sig { params(link: Materializer::Materialized).returns(String) }
      def describe(link)
        name = link.link.basename.to_s
        entry = link.entry
        return "#{name}  (stale — not declared; run `dev skills sync`)  -> #{link.target}" if entry.nil?

        provenance = [entry.package, entry.version].compact.join(" ")
        provenance.empty? ? "#{name}  -> #{link.target}" : "#{name}  [#{provenance}]  -> #{link.target}"
      end
    end
  end
end
