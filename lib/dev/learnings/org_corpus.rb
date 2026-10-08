# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../skills/corpus_channel"
require_relative "../skills/layout"
require_relative "cache"

module Dev
  module Learnings
    # The org tier's on-demand skills (the knowledge repo's `skills/`
    # corpus, as cached on this machine), as a skills channel. The same on
    # every project, so it lands user-globally; the learnings synchronizer
    # hands it to `Dev::Skills` after each cache refresh. Before the first
    # clone lands the corpus is empty and the channel declares nothing.
    class OrgCorpus < Dev::Skills::CorpusChannel
      extend T::Sig

      NAME = "org"

      # @param cache [Dev::Learnings::Cache] the knowledge repo's machine cache
      # @param root [Pathname, String] where the links land (override for tests)
      sig { params(cache: Cache, root: T.any(Pathname, String)).void }
      def initialize(cache:, root: Dev::Skills::Layout.user_global_root)
        super(name: NAME, root: root, corpus_root: cache.skills_dir)
      end
    end
  end
end
