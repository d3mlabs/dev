# frozen_string_literal: true

require "pathname"
require_relative "../skill_installer"

module Dev
  module Learnings
    # The canonical learnings layout, both tiers — the single owner of where
    # the learning loop's committed files live and what an empty index looks
    # like. Everything in dev that touches the layout (the `dev learnings
    # init` scaffold, the knowledge cache, future subcommands) reads from
    # here; ai-flow mirrors these paths as data with a pointer comment back
    # at this module.
    #
    # - Repo tier: an always-on index rule plus committed detail skills,
    #   inside a repo's .cursor/ tree.
    # - Org tier: the knowledge repo's root index — whose fixed section
    #   headings InvariantsRenderer parses — plus the on-demand skills
    #   corpus beside it.
    module Layout
      REPO_INDEX_SUBDIRS = [".cursor", "rules", "learnings-index.mdc"].freeze
      REPO_SKILLS_SUBDIRS = [".cursor", "skills", "learnings"].freeze

      ORG_INDEX_FILENAME = "index.md"
      ORG_SKILLS_DIRNAME = "skills"

      # The empty repo-tier index: the canonical front matter (`alwaysApply:
      # true` is what makes the index load always-on — an improvised index
      # without it is written but never read), the capture/curation
      # preamble, the soft cap, and the org-tier trailer. No entries:
      # capture passes and humans own those.
      REPO_INDEX_SCAFFOLD = <<~SCAFFOLD
        ---
        description: Always-on index of this repo's learnings — lessons distilled from reviews, builds, and scans. Read the pointed skill before working in an entry's territory.
        alwaysApply: true
        ---

        # Learnings index

        One line per learning: `[domain/slug]`, the trigger sentence, the skill
        pointer. The line buys awareness; the pointed skill carries the rule, a
        wrong/right pair, and the origin — read it before working in that entry's
        territory. Detail skills live in `.cursor/skills/learnings/<slug>/`
        (architecture digests in `.cursor/skills/architecture/<topic>/`); gem and
        org skills are pointed at wherever their channel installs them.

        Capture and curation go through the capture-learning skill (IDE sessions)
        or ai-flow's `/learn` (GitHub comments) — both land as proposal PRs; human
        merge is the gate. Soft cap ~50 entries: at the cap, an addition must
        propose a retirement, a consolidation, or a glob-scoped sub-index split.

        ## org tier

        Org-wide invariants and knowledge live in the configured org knowledge
        repo (`knowledge_repo:`), not here: dev renders the always-on slice once
        machine-side and links it in as `.cursor/rules/org-invariants.mdc`, and
        links the on-demand corpus into `~/.cursor/skills/`. A lesson about how
        we build software — not about this repo — belongs there.
      SCAFFOLD

      # The empty org-tier index: the fixed section structure `dev learnings
      # sync` parses. The invariants section carries only entry lines —
      # everything in it is rendered into every project on every machine.
      ORG_INDEX_SCAFFOLD = <<~SCAFFOLD
        # Org learnings index

        The org tier of the learning loop: invariants and knowledge about how
        we build software, not about any one repo. One line per entry:
        `[domain/slug]`, the trigger sentence, the skill pointer into
        `skills/<slug>/`. The line buys awareness; the pointed skill carries
        the rule — dev links the corpus into `~/.cursor/skills/` on every
        machine.

        The two section headings below are fixed — dev parses them. The
        `## Invariants (always-on)` section is rendered into every project as
        an always-on rule, so it carries only entry lines, never prose.

        ## Invariants (always-on)

        ## Knowledge (on-demand)
      SCAFFOLD

      module_function

      # @param repo_root [Pathname, String] a participating repo's root
      # @return [Pathname] the repo tier's always-on index rule
      def repo_index_file(repo_root)
        Pathname(repo_root).join(*REPO_INDEX_SUBDIRS)
      end

      # @param repo_root [Pathname, String] a participating repo's root
      # @param slug [String] the learning's slug
      # @return [Pathname] the repo-tier detail skill for the slug
      def repo_skill_file(repo_root, slug)
        Pathname(repo_root).join(*REPO_SKILLS_SUBDIRS, slug, SkillInstaller::SKILL_FILE)
      end

      # @param org_root [Pathname, String] a knowledge repo checkout (or cache)
      # @return [Pathname] the org tier's index
      def org_index_file(org_root)
        Pathname(org_root) / ORG_INDEX_FILENAME
      end

      # @param org_root [Pathname, String] a knowledge repo checkout (or cache)
      # @return [Pathname] the org tier's on-demand skills corpus
      def org_skills_dir(org_root)
        Pathname(org_root) / ORG_SKILLS_DIRNAME
      end

      # @param org_root [Pathname, String] a knowledge repo checkout (or cache)
      # @param slug [String] the skill's slug
      # @return [Pathname] the org-tier skill for the slug
      def org_skill_file(org_root, slug)
        org_skills_dir(org_root) / slug / SkillInstaller::SKILL_FILE
      end
    end
  end
end
