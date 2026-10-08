# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Skills
    # Where skills live and land — the single owner of the discovery roots
    # dev materializes into and of the location of dev's own shipped set.
    # Channels take their `root` from here; nothing else in dev spells these
    # paths.
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

      # The project-scoped discovery root, relative to a project. Agent-neutral
      # (`.agents/`, not `.cursor/`) so the mechanism isn't tied to one agent.
      PROJECT_ROOT_SUBDIRS = [".agents", "skills"].freeze

      module_function

      # @param home [Pathname, String] the user's home (override for tests)
      # @return [Pathname] the user-global discovery root — the same corpus
      #   for every project on the machine lands here
      sig { params(home: T.any(Pathname, String)).returns(Pathname) }
      def user_global_root(home: Dir.home)
        Pathname.new(home) / ".cursor" / "skills"
      end

      # @param project_root [Pathname, String] a project's root
      # @return [Pathname] the project-scoped discovery root — skills that
      #   differ per project (a lockfile's) land here
      sig { params(project_root: T.any(Pathname, String)).returns(Pathname) }
      def project_root(project_root)
        Pathname.new(project_root).join(*PROJECT_ROOT_SUBDIRS)
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
    end
  end
end
