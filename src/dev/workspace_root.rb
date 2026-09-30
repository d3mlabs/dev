# typed: strict
# frozen_string_literal: true

require "pathname"

module Dev
  # Where the workspace-global commands (`plan`, `learnings`) anchor
  # themselves, classified against the cwd per call rather than once per
  # process: a global command can be invoked from any directory, so its
  # anchor must follow the cwd, not the Runner's memoized dev.yml.
  module WorkspaceRoot
    extend T::Sig

    class << self
      extend T::Sig

      # The workspace root: the nearest ancestor with a dev.yml, else the
      # nearest git repo root, else the cwd itself — so `dev plan` works in
      # any checkout, dev.yml or not.
      #
      # @return [Pathname]
      sig { returns(Pathname) }
      def workspace
        enclosing_project || Pathname.new(Dir.pwd)
      end

      # The enclosing project (nearest dev.yml, else nearest git root), or
      # nil when the cwd sits in no project at all — `dev learnings` outside
      # any checkout does only the machine-global work.
      #
      # @return [Pathname, nil]
      sig { returns(T.nilable(Pathname)) }
      def enclosing_project
        nearest_dev_yaml || nearest_git
      end

      # The nearest ancestor holding a dev.yml, or nil. This is the "inside a
      # project?" test the global help fallback uses: a plain git checkout
      # with no dev.yml still gets the global usage. Same ascent the Runner
      # uses, but un-memoized.
      #
      # @return [Pathname, nil]
      sig { returns(T.nilable(Pathname)) }
      def nearest_dev_yaml
        Dev.search_dev_yaml_file&.dirname
      end

      # @return [Pathname, nil] the nearest ancestor holding a .git, or nil
      sig { returns(T.nilable(Pathname)) }
      def nearest_git
        Pathname.new(Dir.pwd).ascend do |path|
          return path if (path / ".git").exist?
        end
        nil
      end
    end
  end
end
