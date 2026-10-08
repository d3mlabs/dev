# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Skills
    # One skill a channel wants materialized: the link name inside the
    # channel's root (a relative path — `<integration>/<package>/<skill>`
    # for package-shipped skills, the bare skill name for a corpus) and the
    # skill directory (carrying a SKILL.md) it points at. `package` /
    # `version` are provenance for channels whose skills ride an installed
    # artifact (a gem); the channels whose skills are their own corpus leave
    # them nil.
    class Entry < T::Struct
      extend T::Sig

      const :link_name, String
      const :source, Pathname
      const :package, T.nilable(String), default: nil
      const :version, T.nilable(String), default: nil

      # @return [String] the skill's name — the leaf folder, which the skills
      #   spec requires to match the frontmatter `name`
      sig { returns(String) }
      def name
        File.basename(link_name)
      end
    end

    # The seam between a producer of skills and the materializer that places
    # them. A producer (dev's own shipped set, the org knowledge corpus, the
    # locked gem set, a future integration) owns *what* its skills are —
    # where they come from, what version they are at — and hands that over
    # as a channel; `Dev::Skills` owns *where they land* and *how they are
    # recorded*, and never learns the producer's vocabulary.
    #
    # `root` is a channel property, not a materializer one: a corpus that is
    # the same for every project on the machine (dev's own skills, the org
    # tier) lands user-globally; a set that differs per lockfile (gem skills)
    # lands project-scoped. One materializer serves both, keeping one
    # manifest per root.
    module Channel
      extend T::Sig
      extend T::Helpers

      interface!

      # @return [String] the channel's short name (`dev`, `org`, `gem`, …) —
      #   the integration segment of its link names, and what status groups by
      sig { abstract.returns(String) }
      def name; end

      # @return [Pathname] the skills directory this channel's links live in
      sig { abstract.returns(Pathname) }
      def root; end

      # Whether the root sits inside a project checkout (as opposed to the
      # user's home). A project-scoped root must never be committed, so the
      # materializer makes it ignore itself.
      #
      # @return [Boolean]
      sig { abstract.returns(T::Boolean) }
      def project_scoped?; end

      # The full set the channel currently declares. A skill that has
      # disappeared from the producer is simply absent here — that is how
      # the materializer learns to prune its link (against the manifest of
      # what it placed last time).
      #
      # @return [Array<Dev::Skills::Entry>]
      sig { abstract.returns(T::Array[Entry]) }
      def entries; end
    end
  end
end
