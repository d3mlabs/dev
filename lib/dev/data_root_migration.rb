# typed: strict
# frozen_string_literal: true

require "fileutils"
require "stringio"

module Dev
  # The one-off move of a per-user `~/.dev` into a machine data root — the
  # Mac's shared root (AgentBootstrap, plans#26) or Linux's `/var/lib/dev`
  # (LinuxDataRootProvisioner, dev#308). Artifact trees (engines, caches,
  # steam depots) move as a rename, so multi-GB engine trees cost nothing;
  # mutable per-user state (`state`) stays per-home (plans#26's pollution
  # rule: sharing is for immutable artifacts and cooperative caches, never
  # mutable state). Entries the destination already holds are skipped:
  # anything cheap is re-materialized by the next `dev up`, and a newer
  # shared tree must never be clobbered by a stale home one.
  class DataRootMigration
    extend T::Sig

    # The one entry that never moves.
    PER_USER = "state"

    # @param from [String] the per-user root (`~/.dev`, expanded)
    # @param to [String] the machine root, already present and writable
    # @param out [IO, StringIO]
    sig { params(from: String, to: String, out: T.any(IO, StringIO)).void }
    def initialize(from:, to:, out: $stdout)
      @from = from
      @to = to
      @out = out
    end

    # Move every artifact entry that the destination lacks; a no-op when
    # there is no per-user root.
    #
    # @return [void]
    sig { void }
    def run!
      return unless File.directory?(@from)

      Dir.children(@from).sort.each do |entry|
        next if entry == PER_USER

        destination = File.join(@to, entry)
        if File.exist?(destination)
          @out.puts ">>> Skipping ~/.dev/#{entry} (already present in #{@to})."
          next
        end

        @out.puts ">>> Migrating ~/.dev/#{entry} to #{destination} ..."
        FileUtils.mv(File.join(@from, entry), destination)
      end
    end
  end
end
