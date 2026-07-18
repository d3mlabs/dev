# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module Dev
  module Plan
    # Dispatch for `dev plan …` — the local half of ai-flow. The GitHub issue
    # is the canonical plan; the local `.plan.md` is a transient working copy.
    # Every mutation goes through the conflict guard: a push refuses when the
    # remote body changed since the recorded merge base, so the local copy can
    # never clobber newer remote edits.
    class Accessor
      # RuntimeError so Dev::Runner's clean-error rescue prints the usage
      # instead of a backtrace (same for the other plan error classes).
      class UsageError < RuntimeError; end

      USAGE = <<~USAGE.strip
        usage: dev plan <subcommand>
          dev plan new "<title>" [--org]        create an issue + linked local plan
          dev plan link <n> [<file>] [--org]    attach a plan file to issue #n
          dev plan link <file> [--org]          create an issue from a plan file
          dev plan pull <n> [--merge] [--org]   fetch the issue into the local plan
          dev plan push [<file>]                update the issue body (guarded)
          dev plan status                       sync state of all linked plans
      USAGE

      # @param project_root [Pathname] the workspace root (from dev's context)
      # @param workspace [Dev::Plan::Workspace, nil]
      # @param issues [Dev::Plan::GithubIssues, nil]
      # @param settings [Dev::Plan::Settings, nil]
      # @param merge_base [Dev::Plan::MergeBase, nil]
      # @param skill_installer [Dev::Plan::SkillInstaller, nil]
      # @param executor [Dev::Plan::Executor] CLI boundary (injectable for tests)
      def initialize(project_root:, executor: Executor.new, workspace: nil, issues: nil,
                     settings: nil, merge_base: nil, skill_installer: nil)
        @executor = executor
        @workspace = workspace || Workspace.new(project_root: project_root, executor: executor)
        @issues = issues || GithubIssues.new(executor: executor)
        @settings = settings || Settings.new
        @merge_base = merge_base || MergeBase.new
        @skill_installer = skill_installer || SkillInstaller.new
      end

      # Dispatch a `dev plan …` invocation.
      #
      # @param args [Array<String>] argv after the "plan" command
      # @param out [IO] output stream
      # @param input [IO] input stream (the Cursor hook payload for hook-after-edit)
      # @raise [UsageError] on an unrecognized invocation
      def run(args, out: $stdout, input: $stdin)
        @skill_installer.ensure_installed
        subcommand, *rest = args
        case subcommand
        when "new" then new_plan(rest, out:)
        when "link" then link(rest, out:)
        when "pull" then pull(rest, out:)
        when "push" then push(rest, out:)
        when "status" then status(out:)
        when "hook-after-edit" then hook_after_edit(input, out:)
        else raise UsageError, USAGE
        end
      end

      private

      # `dev plan new "<title>" [--org]` — create the issue first (it is
      # canonical from birth), then materialize the linked local working copy.
      # Org plans are scaffolded with a `Target repos:` line: they usually
      # span repos, and the line narrows /split's routing menu (see ai-flow's
      # docs/plan-lifecycle.md). Left blank it is inert — the menu falls back
      # to every org repo.
      def new_plan(args, out:)
        org = args.delete("--org") ? true : false
        title = args.shift
        raise UsageError, "usage: dev plan new \"<title>\" [--org]" if title.nil? || title.empty? || !args.empty?

        owner_repo = target_repo(org:)
        body = "# #{title}\n"
        body += "\nTarget repos:\n<!-- comma-separated owner/repo list — declares scope; /split routes sub-issues within it -->\n" if org
        issue = @issues.create(owner_repo, title: title, body: Plan.to_issue_body(body))
        path = write_linked_plan(owner_repo, issue, body)
        out.puts "dev: created #{owner_repo}##{issue.number} (#{issue.html_url})"
        out.puts "dev: plan file: #{path}"
      end

      # `dev plan link <n> [<file>] [--org]` attaches a plan file to an
      # existing issue (local content stays; `push` publishes it), while
      # `dev plan link <file> [--org]` creates the issue from the file.
      def link(args, out:)
        org = args.delete("--org") ? true : false
        first, second = args
        raise UsageError, "usage: dev plan link <n> [<file>] | link <file> [--org]" if first.nil?

        if first.match?(/\A\d+\z/)
          link_to_existing(Integer(first), second, org:, out:)
        else
          create_from_file(first, org:, out:)
        end
      end

      def link_to_existing(number, file, org:, out:)
        path = file ? Pathname.new(file) : sole_unlinked_plan
        plan = Content.parse(path.read)
        raise UsageError, "#{path} is already linked to #{plan.header.issue_ref}" if plan.header

        owner_repo = target_repo(org:)
        issue = @issues.get(owner_repo, number)
        # Record the remote as the sync point but keep the local content: the
        # file is a draft ahead of the issue until `dev plan push` publishes it.
        new_header = Header.new(owner_repo: owner_repo, number: issue.number, synced_at: issue.updated_at)
        target = move_into_convention(path, owner_repo, issue)
        target.write(plan.with_header(new_header).render)
        @merge_base.write(owner_repo, issue.number, Plan.from_issue_body(issue.body))
        out.puts "dev: linked #{target} to #{owner_repo}##{issue.number} (#{issue.html_url})"
        out.puts "dev: local content kept — run `dev plan push` to publish it."
      end

      def create_from_file(file, org:, out:)
        path = Pathname.new(file)
        raise UsageError, "no such plan file: #{path}" unless path.exist?

        plan = Content.parse(path.read)
        raise UsageError, "#{path} is already linked to #{plan.header.issue_ref}" if plan.header

        owner_repo = target_repo(org:)
        title = extract_title(plan.body) || path.basename(".plan.md").to_s
        issue = @issues.create(owner_repo, title: title, body: Plan.to_issue_body(plan.body))
        target = move_into_convention(path, owner_repo, issue)
        write_linked_plan(owner_repo, issue, plan.body, path: target, frontmatter: plan.frontmatter)
        out.puts "dev: created #{owner_repo}##{issue.number} from #{path} (#{issue.html_url})"
        out.puts "dev: plan file: #{target}"
      end

      # `dev plan pull <n> [--merge] [--org]` — fetch the issue into the local
      # plan. A clean local copy is overwritten; a diverged one needs --merge
      # (3-way against the recorded base) so local work is never discarded.
      def pull(args, out:)
        org = args.delete("--org") ? true : false
        merge = args.delete("--merge") ? true : false
        number_arg = args.shift
        raise UsageError, "usage: dev plan pull <n> [--merge] [--org]" if number_arg.nil? || !args.empty?

        owner_repo = target_repo(org:)
        number = Integer(number_arg)
        issue = @issues.get(owner_repo, number)
        remote_body = Plan.from_issue_body(issue.body)
        path = find_linked_plan(owner_repo, number) || @workspace.plan_path(owner_repo, number, issue.title)

        unless path.exist?
          write_linked_plan(owner_repo, issue, remote_body, path: path)
          out.puts "dev: pulled #{owner_repo}##{number} into #{path}"
          return
        end

        plan = Content.parse(path.read)
        base = @merge_base.read(owner_repo, number)
        local_dirty = base.nil? ? false : plan.body != base
        remote_dirty = base.nil? ? true : remote_body != base

        if !local_dirty
          write_linked_plan(owner_repo, issue, remote_body, path: path, frontmatter: plan.frontmatter)
          out.puts(remote_dirty ? "dev: pulled #{owner_repo}##{number} into #{path}" : "dev: #{path} is already up to date.")
        elsif !remote_dirty
          out.puts "dev: local plan is ahead of #{owner_repo}##{number} — nothing to pull. Run `dev plan push`."
        elsif merge
          merge_pull(path, issue, owner_repo, number, plan, base, remote_body, out:)
        else
          raise "both #{path} and #{owner_repo}##{number} changed since the last sync — " \
                "run `dev plan pull #{number} --merge`."
        end
      end

      def merge_pull(path, issue, owner_repo, number, plan, base, remote_body, out:)
        result = Merge.three_way(local: plan.body, base: base, remote: remote_body, executor: @executor)
        # The remote becomes the new base either way: the merged local copy is
        # now "ahead" of the issue, and `push` publishes it. Frontmatter is
        # carried through from the local side untouched.
        header = Header.new(owner_repo: owner_repo, number: number, synced_at: issue.updated_at)
        path.write(plan.with_header(header).with_body(result.content).render)
        @merge_base.write(owner_repo, number, remote_body)
        if result.conflicts?
          out.puts "dev: merged with conflicts — resolve the markers in #{path}, then run `dev plan push`."
        else
          out.puts "dev: merged #{owner_repo}##{number} into #{path} — run `dev plan push` to publish."
        end
      end

      # `dev plan push [<file>]` — PATCH the issue body iff the remote hasn't
      # changed since the recorded base; otherwise fail with instructions. The
      # target repo comes from the file's header, so org-wide plans push
      # transparently.
      def push(args, out:)
        file = args.shift
        raise UsageError, "usage: dev plan push [<file>]" unless args.empty?

        path = file ? Pathname.new(file) : sole_linked_plan
        plan = Content.parse(path.read)
        raise UsageError, "#{path} has no ai-flow header — link it first with `dev plan link`." unless plan.header
        raise "#{path} contains unresolved merge conflict markers — resolve them before pushing." if plan.body.include?("<<<<<<<")

        header = plan.header
        issue = @issues.get(header.owner_repo, header.number)
        remote_body = Plan.from_issue_body(issue.body)
        base = @merge_base.read(header.owner_repo, header.number)

        # Guard: refuse when the remote body diverged from the base recorded at
        # last sync. Comparing bodies (not updated_at) keeps comments/labels —
        # which also bump updated_at — from blocking a legitimate push.
        remote_changed = base ? remote_body != base : issue.updated_at != header.synced_at
        if remote_changed
          raise "#{header.issue_ref} changed since the last sync — " \
                "run `dev plan pull #{header.number} --merge`, then push again."
        end

        if plan.body == remote_body
          record_sync(path, plan, issue)
          out.puts "dev: #{header.issue_ref} is already in sync."
          return
        end

        title = extract_title(plan.body)
        updated = @issues.update(
          header.owner_repo, header.number,
          body: Plan.to_issue_body(plan.body),
          title: (title if title && title != issue.title),
        )
        record_sync(path, plan, updated)
        out.puts "dev: pushed #{path} to #{header.issue_ref} (#{updated.html_url})"
      end

      # `dev plan hook-after-edit` — the Cursor afterFileEdit hook entry point.
      # Reads the hook's JSON payload from stdin and no-ops unless the edited
      # file is a linked plan in this workspace; a linked plan auto-pushes
      # through the same guarded sync (a guard refusal raises, surfacing in
      # Cursor's Hooks channel — exactly when the user must pull --merge).
      def hook_after_edit(input, out:)
        payload = JSON.parse(input.read)
        edited = payload["file_path"] || payload["filePath"]
        return if edited.nil? || edited.empty?

        path = Pathname.new(edited)
        return unless path.to_s.end_with?(".plan.md") && path.exist?
        return unless path.expand_path.to_s.start_with?(@workspace.plans_dir.expand_path.to_s)

        plan = Content.parse(path.read)
        return unless plan.header

        push([path.to_s], out:)
      end

      # `dev plan status` — sync state of every linked plan in the workspace:
      # clean / ahead (local edits) / behind (remote edits) / diverged (both).
      def status(out:)
        files = @workspace.linked_plan_files
        if files.empty?
          out.puts "dev: no linked plans in #{@workspace.plans_dir}."
          return
        end

        files.each do |path|
          plan = Content.parse(path.read)
          issue = @issues.get(plan.header.owner_repo, plan.header.number)
          state = sync_state(plan.header, plan.body, Plan.from_issue_body(issue.body))
          out.puts "#{state.ljust(10)} #{plan.header.issue_ref.ljust(30)} #{path}"
        end
      end

      def sync_state(header, local_body, remote_body)
        base = @merge_base.read(header.owner_repo, header.number)
        return "unknown" if base.nil?

        local_dirty = local_body != base
        remote_dirty = remote_body != base
        if local_dirty && remote_dirty then "diverged"
        elsif local_dirty then "ahead"
        elsif remote_dirty then "behind"
        else "clean"
        end
      end

      # @param org [Boolean] true targets the configured org plans repo
      # @return [String] "owner/repo"
      def target_repo(org:)
        org ? @settings.plans_repo : @workspace.origin_repo
      end

      # Write the plan file (header + optional frontmatter + markdown body) and
      # refresh the merge base — the single definition of "synced". The merge
      # base stores the markdown body only.
      #
      # @param owner_repo [String]
      # @param issue [Dev::Plan::GithubIssues::Issue]
      # @param body [String] markdown body
      # @param path [Pathname, nil]
      # @param frontmatter [String, nil] Cursor YAML block to preserve locally
      # @return [Pathname] the written path
      def write_linked_plan(owner_repo, issue, body, path: nil, frontmatter: nil)
        path ||= @workspace.plan_path(owner_repo, issue.number, issue.title)
        header = Header.new(owner_repo: owner_repo, number: issue.number, synced_at: issue.updated_at)
        FileUtils.mkdir_p(path.dirname)
        path.write(Content.new(header: header, frontmatter: frontmatter, body: body).render)
        @merge_base.write(owner_repo, issue.number, body)
        path
      end

      # @param path [Pathname]
      # @param plan [Dev::Plan::Content]
      # @param issue [Dev::Plan::GithubIssues::Issue]
      def record_sync(path, plan, issue)
        path.write(plan.with_synced_at(issue.updated_at).render)
        @merge_base.write(plan.header.owner_repo, plan.header.number, plan.body)
      end

      # Move a freshly linked file to the `gh-<n>-<slug>.plan.md` convention
      # inside the workspace plans dir (no-op when it's already there).
      #
      # @return [Pathname] the conventional path
      def move_into_convention(path, owner_repo, issue)
        target = @workspace.plan_path(owner_repo, issue.number, issue.title)
        return path if path.expand_path == target.expand_path

        FileUtils.mkdir_p(target.dirname)
        FileUtils.mv(path, target)
        target
      end

      # @param body [String]
      # @return [String, nil] the first H1 heading, which doubles as the title
      def extract_title(body)
        body[/^# (.+)$/, 1]&.strip
      end

      # @return [Pathname]
      def find_linked_plan(owner_repo, number)
        @workspace.linked_plan_files.find do |path|
          plan = Content.parse(path.read)
          plan.header.owner_repo == owner_repo && plan.header.number == number
        end
      end

      def sole_linked_plan
        files = @workspace.linked_plan_files
        raise UsageError, "no linked plans in #{@workspace.plans_dir} — link one first." if files.empty?
        return files.fetch(0) if files.size == 1

        raise UsageError, "multiple linked plans — specify one: dev plan push <file>\n  #{files.join("\n  ")}"
      end

      def sole_unlinked_plan
        files =
          if @workspace.plans_dir.directory?
            @workspace.plans_dir.glob(Workspace::PLAN_GLOB).sort.reject do |path|
              Content.parse(path.read).header
            end
          else
            []
          end
        return files.fetch(0) if files.size == 1

        raise UsageError, "specify the plan file: dev plan link <n> <file>"
      end
    end
  end
end
