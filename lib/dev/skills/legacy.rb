# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "layout"

module Dev
  module Skills
    # The one-time migration off the pre-#250 flat gem layout: the
    # `.agents/skills/gem-<gem>--<skill>` symlinks dev minted are removed so
    # the project's skills dir holds only the repo's own content plus the
    # `dev/` subtree. Dev's by prefix, so safe to delete by prefix exactly
    # once — the new layout is manifest-tracked and never needs this again.
    module Legacy
      extend T::Sig

      module_function

      # @param project_root [Pathname, String]
      # @return [Array<Pathname>] the links removed
      sig { params(project_root: T.any(Pathname, String)).returns(T::Array[Pathname]) }
      def sweep(project_root)
        links = Layout.legacy_gem_links(project_root)
        links.each { |link| FileUtils.rm_f(link) }
        links
      rescue SystemCallError => e
        $stderr.puts "dev: warning: could not remove legacy gem skill links (#{e.message})."
        []
      end
    end
  end
end
