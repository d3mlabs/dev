# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Plan
    # The canonical plan template — the single owner of the bundled
    # tech-design document (brief sections + Tech design skeleton), the
    # `.github/ISSUE_TEMPLATE/plan.md` mirror convention, and the marker that
    # separates dev-managed mirrors from repo-owned templates. `dev plan new`
    # scaffolds from here (or from a repo's committed mirror) and
    # `dev plan init` materializes the mirror; repos customize by editing the
    # mirror and dropping the marker.
    module Templates
      extend T::Sig

      # The bundled template body, relative to this file (lib/dev/plan/ →
      # repo or libexec root) — the installed location under brew, same
      # resolution as SkillInstaller::SHIPPED_SKILLS_DIR.
      BUNDLE_FILE = T.let(
        Pathname.new(File.expand_path(File.join(__dir__, "..", "..", "..", "share", "plan-templates", "tech-design.md"))),
        Pathname,
      )

      # Where the mirror lives inside a repo — GitHub's issue-template
      # location, so the web UI's "New issue" chooser serves the same
      # document `dev plan new` scaffolds.
      MIRROR_SUBDIRS = [".github", "ISSUE_TEMPLATE", "plan.md"].freeze

      # The mirror path relative to a repo root (for API content fetches).
      MIRROR_RELATIVE_PATH = T.let(File.join(*MIRROR_SUBDIRS), String)

      # Ownership marker: present = dev-managed mirror (init may overwrite,
      # new warns on staleness); absent = repo-owned template (left alone).
      MARKER = "<!-- mirrored from dev share/plan-templates/tech-design.md — do not hand-edit; run `dev plan init` to update -->"

      # GitHub issue-template front matter for the mirror.
      GITHUB_FRONT_MATTER = <<~FRONT_MATTER
        ---
        name: Tech design
        about: A project plan born at brief stage — fill in the Tech design section once accepted.
        ---
      FRONT_MATTER

      # A leading YAML front-matter block (GitHub issue templates carry one).
      FRONT_MATTER_PATTERN = /\A---\n.*?\n---\n/m

      module_function

      # @return [String] the bundled template body (markdown sections only)
      sig { returns(String) }
      def bundle_body
        BUNDLE_FILE.read
      end

      # @param repo_root [Pathname, String] a repo checkout root
      # @return [Pathname] the repo's plan template mirror
      sig { params(repo_root: T.any(Pathname, String)).returns(Pathname) }
      def mirror_path(repo_root)
        Pathname.new(repo_root).join(*MIRROR_SUBDIRS)
      end

      # The mirror file content: GitHub front matter, the ownership marker,
      # then the bundled body verbatim.
      #
      # @return [String]
      sig { returns(String) }
      def render_mirror
        "#{GITHUB_FRONT_MATTER}#{MARKER}\n\n#{bundle_body}"
      end

      # Extract the template body from a repo's template file — front matter
      # and the marker are wrapper, not body.
      #
      # @param content [String] a plan template file's content
      # @return [String] the markdown body to scaffold into a new plan
      sig { params(content: String).returns(String) }
      def body_of(content)
        content
          .sub(FRONT_MATTER_PATTERN, "")
          .sub("#{MARKER}\n", "")
          .sub(/\A\n+/, "")
      end

      # @param content [String] a plan template file's content
      # @return [Boolean] whether the content is a dev-managed mirror
      sig { params(content: String).returns(T::Boolean) }
      def mirrored?(content)
        content.include?(MARKER)
      end

      # Whether a dev-managed mirror drifted from the current bundle render.
      # Repo-owned templates (no marker) are customizations, never stale.
      #
      # @param content [String] a plan template file's content
      # @return [Boolean]
      sig { params(content: String).returns(T::Boolean) }
      def stale?(content)
        mirrored?(content) && content != render_mirror
      end
    end
  end
end
