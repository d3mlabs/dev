# typed: strict
# frozen_string_literal: true

require "json"
require "pathname"
require "stringio"
require_relative "channel"
require_relative "legacy"
require_relative "materializer"

module Dev
  module Skills
    # Dispatch for `dev skills …` — the explicit surface over skill
    # materialization. Passive materialization rides dev's hook points
    # (`dev up` / `dev deps install` / `dev plan`); these verbs are the
    # manual override and the inspection, across every channel at once:
    #
    # - `status` — the manifests, grouped by channel: each link, the package
    #              and version it was minted from (when the channel knows
    #              them), its source, and whether it still stands. Skills
    #              sharing a name across channels are listed as plain
    #              information, like `which -a` — all of them load, the
    #              agent sees each by path. `--json` for tooling.
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
      # @param project_root [Pathname, String, nil] the enclosing project, for
      #   the one-time legacy sweep on sync; nil outside any project
      # @param materializer [Dev::Skills::Materializer]
      sig do
        params(
          channels: T::Array[Channel],
          project_root: T.nilable(T.any(Pathname, String)),
          materializer: Materializer,
        ).void
      end
      def initialize(channels:, project_root: nil, materializer: Materializer.new)
        @channels = channels
        @project_root = project_root
        @materializer = materializer
      end

      # `dev skills status [--json]`: each channel's root and its recorded
      # links, then the same-name groups.
      #
      # @param out [IO, StringIO]
      # @param json [Boolean] machine-readable instead of the table
      # @return [void]
      sig { params(out: T.any(IO, StringIO), json: T::Boolean).void }
      def status(out:, json: false)
        report = @channels.map { |channel| [channel, @materializer.materialized(channel)] }
        return out.puts(JSON.pretty_generate(json_report(report))) if json

        report.each do |channel, links|
          out.puts "dev: #{channel.name} skills: #{links.size} linked under #{channel.root}"
          links.each { |link| out.puts "  #{describe(link)}" }
        end
        print_same_named(out, report)
      end

      # `dev skills sync`: materialize every channel now (sweeping the
      # project's pre-#250 flat gem links first, like the hooks do).
      #
      # @param out [IO, StringIO]
      # @return [void]
      sig { params(out: T.any(IO, StringIO)).void }
      def sync(out:)
        project_root = @project_root
        Legacy.sweep(project_root) if project_root
        @materializer.sync(@channels)
        @channels.each do |channel|
          out.puts "dev: #{channel.name} skills: #{@materializer.materialized(channel).size} materialized under #{channel.root}."
        end
      end

      private

      Report = T.type_alias { T::Array[[Channel, T::Array[Materializer::Materialized]]] }

      # One status line: the link, its provenance when known, the source,
      # and a flag when the link no longer matches its record.
      #
      # @param link [Dev::Skills::Materializer::Materialized]
      # @return [String]
      sig { params(link: Materializer::Materialized).returns(String) }
      def describe(link)
        record = link.record
        parts = [record.link]
        provenance = [record.package, record.version].compact.join(" ")
        parts << "[#{provenance}]" unless provenance.empty?
        parts << "-> #{record.source}"
        parts << "(missing — run `dev skills sync`)" unless link.present
        parts.join("  ")
      end

      # Skills whose name appears under more than one channel/package —
      # expected with several ecosystems, listed so nobody has to diff roots
      # to notice.
      #
      # @param out [IO, StringIO]
      # @param report [Array]
      # @return [void]
      sig { params(out: T.any(IO, StringIO), report: Report).void }
      def print_same_named(out, report)
        by_name = report.flat_map { |_channel, links| links.map(&:record) }.group_by(&:name)
        groups = by_name.select { |_name, records| records.size > 1 }.sort
        return if groups.empty?

        out.puts "dev: same-named skills (all load; the agent sees each by path):"
        groups.each do |name, records|
          out.puts "  #{name} ← #{records.map { |record| origin(record) }.join(", ")}"
        end
      end

      # @param record [Dev::Skills::Manifest::Record]
      # @return [String] `gem/rspock 3.0.0`, or just `org` for a corpus skill
      sig { params(record: Manifest::Record).returns(String) }
      def origin(record)
        origin = record.package ? "#{record.integration}/#{record.package}" : record.integration
        record.version ? "#{origin} #{record.version}" : origin
      end

      # @param report [Array]
      # @return [Hash] the `--json` shape
      sig { params(report: Report).returns(T::Hash[String, T.untyped]) }
      def json_report(report)
        {
          "channels" => report.map do |channel, links|
            {
              "name" => channel.name,
              "root" => channel.root.to_s,
              "skills" => links.map { |link| link.record.to_json_hash.merge("present" => link.present) },
            }
          end,
        }
      end
    end
  end
end
