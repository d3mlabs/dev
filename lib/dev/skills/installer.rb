# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  module Skills
    # The symlink primitive: install or remove one skill link inside a skills
    # dir. One instance per target dir. Which links exist and which to prune
    # is the Materializer's call, from what channels declare; this class
    # only knows how to place and remove a link safely.
    #
    # Called from cheap, idempotent hook points (`dev up` / `dev deps
    # install` / `dev plan`), so there is no separate setup step and `brew
    # upgrade` refreshes shipped skills automatically (symlinks resolve
    # through the installed tree, wherever brew put it).
    class Installer
      extend T::Sig

      # @return [Pathname] target dir the symlinks live in
      sig { returns(Pathname) }
      attr_reader :skills_dir

      # @param skills_dir [Pathname, String] target dir the symlinks live in
      # @param tmpdir [Pathname, String] ephemeral temp root that links must
      #   never target; defaults to Dir.tmpdir (override for tests, whose
      #   fixture skill trees themselves live under the real temp dir)
      sig { params(skills_dir: T.any(Pathname, String), tmpdir: T.any(Pathname, String)).void }
      def initialize(skills_dir:, tmpdir: Dir.tmpdir)
        @skills_dir = T.let(Pathname(skills_dir), Pathname)
        @tmpdir_roots = T.let(tmpdir_roots(Pathname(tmpdir)), T::Array[Pathname])
      end

      # Install or refresh one skill symlink. A source that resolves under the
      # temp dir is never linked (warned and skipped): a durable link to
      # purgeable state silently dangles later, whatever produced it — e.g. a
      # dev running from a temp clone would re-point the machine-global links
      # at itself through the shipped skills dir. Never raises: a broken skill
      # install must not block the command it rides (the failure is reported
      # on stderr).
      #
      # @param name [String] link name inside the skills dir
      # @param source_dir [Pathname, String] skill directory the link points at
      # @return [void]
      sig { params(name: String, source_dir: T.any(Pathname, String)).void }
      def install(name, source_dir)
        source = Pathname(source_dir)
        return unless source.directory?

        if ephemeral?(source)
          $stderr.puts "dev: warning: not linking #{name} — #{source} is under the temp dir " \
            "and would dangle once it is purged."
          return
        end

        link = @skills_dir / name
        return if link.symlink? && link.readlink == source

        if link.exist? && !link.symlink?
          $stderr.puts "dev: warning: #{link} exists and is not a symlink — leaving it in place."
          return
        end

        FileUtils.mkdir_p(link.dirname)
        FileUtils.rm_f(link)
        File.symlink(source, link)
      rescue SystemCallError => e
        $stderr.puts "dev: warning: could not install the #{name} skill symlink (#{e.message})."
      end

      # Remove a skill symlink by name, then the empty directories a nested
      # name leaves behind (`gem/rspock/` once its last skill is gone), up to
      # but never including the skills dir. Only symlinks and empty dirs are
      # removed — anything user-owned in the skills dir survives. Never
      # raises: symlink? reports false instead of raising, rm_f's force
      # semantics swallow filesystem errors, and a non-empty parent simply
      # stops the climb.
      #
      # @param name [String] link name inside the skills dir (may be nested)
      # @return [void]
      sig { params(name: String).void }
      def remove(name)
        link = @skills_dir / name
        return unless link.symlink?

        FileUtils.rm_f(link)
        remove_empty_parents(link.dirname)
      end

      private

      # @param dir [Pathname] the removed link's parent
      # @return [void]
      sig { params(dir: Pathname).void }
      def remove_empty_parents(dir)
        skills_dir = @skills_dir.expand_path
        while dir.expand_path != skills_dir && dir.expand_path.to_s.start_with?("#{skills_dir}#{File::SEPARATOR}")
          break unless dir.directory? && dir.empty?

          dir.rmdir
          dir = dir.dirname
        end
      rescue SystemCallError
        nil
      end

      # The temp root in both its raw and fully-resolved forms — on macOS
      # Dir.tmpdir is under /var/... while realpath resolution reports the
      # /private/var/... spelling, so containment must check both.
      #
      # @param tmpdir [Pathname]
      # @return [Array<Pathname>]
      sig { params(tmpdir: Pathname).returns(T::Array[Pathname]) }
      def tmpdir_roots(tmpdir)
        expanded = tmpdir.expand_path
        roots = [expanded]
        roots << expanded.realpath if expanded.exist?
        roots.uniq
      end

      # Whether a path resolves under the temp dir — a durable link to it
      # would dangle once the temp dir is purged, whatever produced it.
      #
      # @param path [Pathname]
      # @return [Boolean]
      sig { params(path: Pathname).returns(T::Boolean) }
      def ephemeral?(path)
        resolved = path.exist? ? path.realpath : path.expand_path
        @tmpdir_roots.any? { |root| resolved.to_s.start_with?("#{root}#{File::SEPARATOR}") }
      end
    end
  end
end
