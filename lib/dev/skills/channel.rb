# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  module Skills
    # One skill a channel wants materialized: the link name inside the
    # channel's root and the skill directory (carrying a SKILL.md) it points
    # at. `package` / `version` are provenance for channels whose skills ride
    # an installed artifact (a gem); the channels whose skills are their own
    # corpus leave them nil.
    class Entry < T::Struct
      extend T::Sig

      const :link_name, String
      const :source, Pathname
      const :package, T.nilable(String), default: nil
      const :version, T.nilable(String), default: nil
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
    # lands project-scoped. One materializer serves both.
    module Channel
      extend T::Sig
      extend T::Helpers

      interface!

      # @return [String] the channel's short name (`dev`, `org`, `gem`, …) —
      #   what status groups by
      sig { abstract.returns(String) }
      def name; end

      # @return [Pathname] the skills directory this channel's links live in
      sig { abstract.returns(Pathname) }
      def root; end

      # The full set the channel currently declares. A skill that has
      # disappeared from the producer is simply absent here — that is how
      # the materializer learns to prune its link.
      #
      # @return [Array<Dev::Skills::Entry>]
      sig { abstract.returns(T::Array[Entry]) }
      def entries; end

      # Whether an existing symlink in the root belongs to this channel.
      # Decides what the materializer may prune: links that are the
      # channel's but no longer declared go; anything else in the root —
      # another channel's, the user's — is never touched.
      #
      # @param link [Pathname] an existing symlink inside `root`
      # @return [Boolean]
      sig { abstract.params(link: Pathname).returns(T::Boolean) }
      def owns?(link); end
    end
  end
end
