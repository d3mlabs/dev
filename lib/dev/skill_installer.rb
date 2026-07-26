# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  # Symlinks skill directories (each carrying a SKILL.md) into a skills dir.
  # One instance per target dir; the three link jobs share the mechanism and
  # differ only in source and target:
  #
  # - dev's own shipped skills (share/cursor-skills/*) → ~/.cursor/skills
  # - org knowledge skills (machine knowledge cache)   → ~/.cursor/skills
  # - gem-shipped skills (lockfile-matched gems)       → <project>/.agents/skills
  #
  # Called from cheap, idempotent hook points (`dev up` / `install-deps` /
  # `dev plan`), so there is no separate setup step and `brew upgrade`
  # refreshes shipped skills automatically (symlinks resolve through the
  # installed tree, wherever brew put it).
  class SkillInstaller
    SKILL_FILE = "SKILL.md"

    # Skills shipped inside dev's own package, relative to this file
    # (lib/dev/ → repo or libexec root) — the installed location under brew.
    SHIPPED_SKILLS_DIR = Pathname(File.expand_path(File.join(__dir__, "..", "..", "share", "cursor-skills")))

    # @param skills_dir [Pathname, String] target dir the symlinks live in;
    #   defaults to the user-global ~/.cursor/skills
    def initialize(skills_dir: Pathname(Dir.home) / ".cursor" / "skills")
      @skills_dir = Pathname(skills_dir)
    end

    # Install or refresh one skill symlink. Never raises: a broken skill
    # install must not block the command it rides (the failure is reported
    # on stderr).
    #
    # @param name [String] link name inside the skills dir
    # @param source_dir [Pathname, String] skill directory the link points at
    # @return [void]
    def install(name, source_dir)
      source = Pathname(source_dir)
      return unless source.directory?

      link = @skills_dir / name
      return if link.symlink? && link.readlink == source

      if link.exist? && !link.symlink?
        $stderr.puts "dev: warning: #{link} exists and is not a symlink — leaving it in place."
        return
      end

      FileUtils.mkdir_p(@skills_dir)
      FileUtils.rm_f(link)
      File.symlink(source, link)
    rescue SystemCallError => e
      $stderr.puts "dev: warning: could not install the #{name} skill symlink (#{e.message})."
    end

    # Install or refresh a symlink for every skill directory (an immediate
    # subdirectory carrying a SKILL.md) under source_root, then prune links
    # into source_root whose skill has since disappeared. Never raises, same
    # as install.
    #
    # @param source_root [Pathname, String] directory of skill directories
    # @param prefix [String] prepended to each link name (e.g. "gem-rspock--")
    # @return [void]
    def install_all(source_root, prefix: "")
      root = Pathname(source_root)
      return unless root.directory?

      root.children.select(&:directory?).sort.each do |skill_dir|
        next unless (skill_dir / SKILL_FILE).file?

        install("#{prefix}#{skill_dir.basename}", skill_dir)
      end
      prune_broken_links(root)
    end

    # Remove a skill symlink by name. Only symlinks are removed — anything
    # user-owned in the skills dir survives. Never raises: symlink? reports
    # false instead of raising, and rm_f's force semantics swallow
    # filesystem errors.
    #
    # @param name [String] link name inside the skills dir
    # @return [void]
    def remove(name)
      link = @skills_dir / name
      FileUtils.rm_f(link) if link.symlink?
    end

    private

    # Prune symlinks that point under source_root but whose target skill no
    # longer exists (e.g. a skill removed from the knowledge repo). Links
    # pointing elsewhere are never touched.
    #
    # @param source_root [Pathname]
    # @return [void]
    def prune_broken_links(source_root)
      return unless @skills_dir.directory?

      @skills_dir.children.each do |link|
        next unless link.symlink?

        target = link.readlink
        next unless target.to_s.start_with?("#{source_root}#{File::SEPARATOR}")

        FileUtils.rm_f(link) unless target.directory?
      end
    rescue SystemCallError => e
      $stderr.puts "dev: warning: could not prune stale skill symlinks (#{e.message})."
    end
  end
end
