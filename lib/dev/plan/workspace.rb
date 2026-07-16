# frozen_string_literal: true

require "pathname"

module Dev
  module Plan
    # The local side of a plan workspace: where plan files live
    # (`.cursor/plans/` in the repo), the `gh-<n>-<slug>.plan.md` naming
    # convention, and resolution of the repo's `owner/repo` from its origin
    # remote (repo-scoped plans target the repo you're standing in).
    class Workspace
      class Error < StandardError; end

      PLAN_GLOB = "*.plan.md"

      # @return [Pathname]
      attr_reader :plans_dir

      # @param project_root [Pathname]
      # @param executor [Dev::Plan::Executor] CLI boundary (injectable for tests)
      def initialize(project_root:, executor: Executor.new)
        @project_root = project_root
        @plans_dir = project_root / ".cursor" / "plans"
        @executor = executor
      end

      # "owner/repo" parsed from the workspace's origin remote.
      #
      # @return [String]
      # @raise [Error] when there is no origin remote or it isn't a GitHub URL
      def origin_repo
        out, err, ok = @executor.capture("git", "-C", @project_root.to_s, "remote", "get-url", "origin")
        raise Error, "could not resolve the origin remote: #{err.strip}" unless ok

        parse_github_remote(out.strip)
      end

      # The conventional path for a linked plan.
      #
      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @param title [String] issue title, slugified into the filename
      # @return [Pathname]
      def plan_path(owner_repo, number, title)
        prefix = (owner_repo == origin_repo_or_nil) ? "" : "#{owner_repo.split("/").fetch(1)}-"
        @plans_dir / "gh-#{prefix}#{number}-#{self.class.slugify(title)}.plan.md"
      end

      # All plan files in the workspace carrying an ai-flow header.
      #
      # @return [Array<Pathname>]
      def linked_plan_files
        return [] unless @plans_dir.directory?

        @plans_dir.glob(PLAN_GLOB).sort.select do |path|
          header, _body = Header.split(path.read)
          !header.nil?
        end
      end

      # @param title [String]
      # @return [String] filesystem-safe slug (bounded length)
      def self.slugify(title)
        slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
        slug = slug[0, 40].to_s.sub(/-\z/, "")
        slug.empty? ? "plan" : slug
      end

      private

      # origin_repo, or nil when the workspace has no usable origin remote
      # (org-wide plans still need a filename, so this must not raise).
      #
      # @return [String, nil]
      def origin_repo_or_nil
        origin_repo
      rescue Error
        nil
      end

      # @param url [String] ssh or https remote URL
      # @return [String] "owner/repo"
      # @raise [Error] for non-GitHub remotes
      def parse_github_remote(url)
        match = url.match(%r{github\.com[:/](?<owner>[^/]+)/(?<repo>[^/\s]+?)(?:\.git)?\z})
        raise Error, "origin remote is not a GitHub URL: #{url}" unless match

        "#{match[:owner]}/#{match[:repo]}"
      end
    end
  end
end
