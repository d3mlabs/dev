# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Skills
    # Where skills live and land — the single owner of the discovery roots
    # dev materializes into, of the shape of the dev-managed subtree inside
    # a project, and of the location of dev's own shipped set. Channels take
    # their `root` from here and build their link names with
    # `channel_link`; nothing else in dev spells these paths.
    #
    # Project layout:
    #
    #   .agents/skills/dev/<integration>/<package>/<skill>/  ->  <installed package>/skills/<skill>/
    #   .agents/skills/dev/manifest.json                     (what dev materialized here, with provenance)
    #   .agents/skills/dev/.gitignore                        (`*` — the subtree ignores itself)
    #
    # `dev/` is the one top-level marker meaning "materialized by dev, never
    # committed"; everything else under `.agents/skills/` is the repo's own,
    # committable content. `<integration>` is the channel, so names never
    # clash across ecosystems; `<skill>` is the leaf = the skill's frontmatter
    # `name`, conforming by construction (lowercase, hyphens, no `--`). No
    # version segment: the leaf must be the skill name, and the lockfile is
    # the single version authority — one link per (integration, package,
    # skill), repointed on bump; the manifest records the version.
    module Layout
      extend T::Sig

      # The file that makes a directory a skill.
      SKILL_FILE = "SKILL.md"

      # Skills shipped inside dev's own package, relative to this file
      # (lib/dev/skills/ → repo or libexec root) — the installed location
      # under brew.
      SHIPPED_SKILLS_DIR = T.let(
        Pathname(File.expand_path(File.join(T.must(__dir__), "..", "..", "..", "share", "cursor-skills"))),
        Pathname,
      )

      # The agent-neutral skills dir inside a project (`.agents/`, not
      # `.cursor/`, so the mechanism isn't tied to one agent) …
      PROJECT_SKILLS_SUBDIRS = T.let([".agents", "skills"].freeze, T::Array[String])
      # … and the dev-managed subtree inside it, the project-scoped root.
      DEV_SUBDIR = "dev"
      PROJECT_ROOT_SUBDIRS = T.let([*PROJECT_SKILLS_SUBDIRS, DEV_SUBDIR].freeze, T::Array[String])

      # Per-root record of what dev materialized there.
      MANIFEST_FILENAME = "manifest.json"

      # The link-name prefix of the pre-#250 flat gem layout
      # (`.agents/skills/gem-<gem>--<skill>`), kept only so the one-time
      # migration can recognize what dev minted.
      LEGACY_GEM_LINK_PREFIX = "gem-"

      module_function

      # @param home [Pathname, String] the user's home (override for tests)
      # @return [Pathname] the user-global discovery root — the same corpus
      #   for every project on the machine lands here
      sig { params(home: T.any(Pathname, String)).returns(Pathname) }
      def user_global_root(home: Dir.home)
        Pathname.new(home) / ".cursor" / "skills"
      end

      # @param project_root [Pathname, String] a project's root
      # @return [Pathname] the project's skills dir, dev-managed subtree included
      sig { params(project_root: T.any(Pathname, String)).returns(Pathname) }
      def project_skills_dir(project_root)
        PROJECT_SKILLS_SUBDIRS.reduce(Pathname.new(project_root)) { |path, segment| path / segment }
      end

      # @param project_root [Pathname, String] a project's root
      # @return [Pathname] the project-scoped discovery root — the
      #   dev-managed subtree where skills that differ per project (a
      #   lockfile's) land
      sig { params(project_root: T.any(Pathname, String)).returns(Pathname) }
      def project_root(project_root)
        PROJECT_ROOT_SUBDIRS.reduce(Pathname.new(project_root)) { |path, segment| path / segment }
      end

      # The link name for a package-shipped skill inside its channel's root:
      # `<integration>/<package>/<skill>`.
      #
      # @param integration [String] the channel's name
      # @param package [String] the lock-resolved package name
      # @param skill [String] the skill's folder name
      # @return [String]
      sig { params(integration: String, package: String, skill: String).returns(String) }
      def channel_link(integration, package, skill)
        File.join(integration, package, skill)
      end

      # @param root [Pathname, String] a discovery root dev materializes into
      # @return [Pathname] that root's manifest
      sig { params(root: T.any(Pathname, String)).returns(Pathname) }
      def manifest_file(root)
        Pathname.new(root) / MANIFEST_FILENAME
      end

      # The skill directories directly under a corpus root: each immediate
      # subdirectory carrying a SKILL.md, sorted for a stable order.
      #
      # @param corpus_root [Pathname, String]
      # @return [Array<Pathname>]
      sig { params(corpus_root: T.any(Pathname, String)).returns(T::Array[Pathname]) }
      def skill_dirs(corpus_root)
        root = Pathname.new(corpus_root)
        return [] unless root.directory?

        root.children.select { |child| child.directory? && (child / SKILL_FILE).file? }.sort
      end

      # The flat gem links of the pre-#250 layout still present in a
      # project's skills dir — dev's by prefix, removed exactly once by the
      # migration.
      #
      # @param project_root [Pathname, String]
      # @return [Array<Pathname>]
      sig { params(project_root: T.any(Pathname, String)).returns(T::Array[Pathname]) }
      def legacy_gem_links(project_root)
        dir = project_skills_dir(project_root)
        return [] unless dir.directory?

        dir.children.select { |child| child.symlink? && child.basename.to_s.start_with?(LEGACY_GEM_LINK_PREFIX) }.sort
      end
    end
  end
end
