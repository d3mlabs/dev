# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "channel"
require_relative "layout"

module Dev
  module Skills
    # A channel whose skills are the subdirectories of one corpus directory,
    # linked under their own names: dev's shipped set, the org knowledge
    # cache. It owns a link when the link targets inside its corpus — so two
    # corpus channels sharing a root (both land user-globally) never prune
    # each other's links.
    class CorpusChannel
      extend T::Sig
      include Channel

      sig { override.returns(String) }
      attr_reader :name

      sig { override.returns(Pathname) }
      attr_reader :root

      # @return [Pathname] the directory whose skill subdirectories this channel declares
      sig { returns(Pathname) }
      attr_reader :corpus_root

      # @param name [String] the channel's short name
      # @param root [Pathname, String] where the links land
      # @param corpus_root [Pathname, String] where the skills come from
      sig { params(name: String, root: T.any(Pathname, String), corpus_root: T.any(Pathname, String)).void }
      def initialize(name:, root:, corpus_root:)
        @name = name
        @root = T.let(Pathname(root), Pathname)
        @corpus_root = T.let(Pathname(corpus_root).expand_path, Pathname)
      end

      sig { override.returns(T::Array[Entry]) }
      def entries
        Layout.skill_dirs(@corpus_root).map { |dir| Entry.new(link_name: dir.basename.to_s, source: dir) }
      end

      sig { override.params(link: Pathname).returns(T::Boolean) }
      def owns?(link)
        link.readlink.expand_path.to_s.start_with?("#{@corpus_root}#{File::SEPARATOR}")
      rescue SystemCallError
        false
      end
    end

    # Dev's own shipped skills (ai-flow, capture-learning, …), the same on
    # every project: materialized user-globally, resolving through the
    # installed tree so a `brew upgrade` refreshes them.
    class OwnSkills < CorpusChannel
      extend T::Sig

      NAME = "dev"

      # @param root [Pathname, String] where the links land (override for tests)
      # @param corpus_root [Pathname, String] the shipped set (override for tests)
      sig { params(root: T.any(Pathname, String), corpus_root: T.any(Pathname, String)).void }
      def initialize(root: Layout.user_global_root, corpus_root: Layout::SHIPPED_SKILLS_DIR)
        super(name: NAME, root: root, corpus_root: corpus_root)
      end
    end
  end
end
