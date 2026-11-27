# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "deps/cmake_integration"
require_relative "deps/luarocks_integration"
require_relative "learnings/layout"
require_relative "plan/workspace"
require_relative "project_shadowenv"
require_relative "shadowenv_python"
require_relative "skills/layout"
require_relative "ui"

module Dev
  # What dev materializes into an adopting repo's checkout that must never
  # be committed — and the one mechanism that makes "gitignored" a fact
  # rather than a README claim. Each producer owns the ignore line for the
  # path it materializes (the constant sits beside the path it covers, so
  # the two cannot drift); this module collects them, writes them into the
  # repo's `.gitignore` under one marker block, and checks them. The list
  # is documented, row for row, in docs/gitignore.md.
  #
  # Two kinds of producer: activation state a `dependencies.rb` directive
  # materializes (the per-side lisps and venv links, the cmake source
  # links, the luarocks tree — every one naming a path on one machine), and
  # the agent links the learnings, skills and plan modules place. The list
  # is unconditional: a project that declares no `python` ignores `.venv`
  # for nothing, which costs a line, where a conditional list would cost a
  # second writer per directive.
  #
  # Idempotency is per path, judged by git itself (`git check-ignore`): a
  # path the user already covers with their own pattern is left alone, a
  # missing one is added inside dev's block. Lines the user wrote are never
  # moved or rewritten.
  module Footprint
    extend T::Sig

    # The comment heading dev's block in a repo's .gitignore.
    HEADER = "# dev-managed paths — rematerialized by `dev up` / `dev deps install` / `dev plan`, never committed"
    # One release's alias of HEADER, from when the block held agent links
    # only: a block under it is dev's and takes new lines (its header is
    # rewritten to HEADER on the way), so no adopter gets a second block.
    # Delete with the next release.
    LEGACY_HEADER = "# dev-managed agent links — rematerialized by `dev up` / `dev deps install` / `dev plan`, never committed"

    # Every path dev materializes into a project, from its owner: the
    # activation state first, in the order `dev up` writes it, then the
    # agent links.
    MANAGED_PATHS = T.let(
      [
        *Dev::ProjectShadowenv::GITIGNORE_FOOTPRINT,
        *Dev::ShadowenvPython::GITIGNORE_FOOTPRINT,
        Dev::Deps::CmakeIntegration::GITIGNORE_FOOTPRINT,
        Dev::Deps::LuaRocksIntegration::GITIGNORE_FOOTPRINT,
        Dev::Learnings::Layout::GITIGNORE_FOOTPRINT,
        Dev::Skills::Layout::GITIGNORE_FOOTPRINT,
        Dev::Plan::Workspace::GITIGNORE_FOOTPRINT,
      ].freeze,
      T::Array[String],
    )

    # The command that repairs a missing line, named in every warning.
    REPAIR_HINT = "run `dev learnings init --gitignore`"

    class << self
      extend T::Sig

      # The paths among `paths` that git does not ignore in the project.
      # Empty outside a git repo (nothing to check against) — the warning is
      # about commits, and there are none to fear there.
      #
      # @param project_root [Pathname, String]
      # @param paths [Array<String>] repo-relative paths
      # @return [Array<String>]
      sig { params(project_root: T.any(Pathname, String), paths: T::Array[String]).returns(T::Array[String]) }
      def missing(project_root, paths)
        root = Pathname(project_root)
        paths.select { |path| ignored?(root, path) == false }
      end

      # One `{{x}}` note per path git does not ignore: a drift fact with
      # its remedy, in the status ledger that checks it.
      #
      # @param ui [Dev::Ui]
      # @param project_root [Pathname, String]
      # @param paths [Array<String>]
      # @return [void]
      sig { params(ui: Dev::Ui, project_root: T.any(Pathname, String), paths: T::Array[String]).void }
      def warn_missing(ui, project_root, paths)
        missing(project_root, paths).each do |path|
          ui.note("{{x}} #{path} is not gitignored — #{REPAIR_HINT}.")
        end
      end

      # Whether git ignores the path in the project: true / false, or nil
      # when git cannot say (not a repo, git missing).
      #
      # @param root [Pathname]
      # @param path [String]
      # @return [Boolean, nil]
      sig { params(root: Pathname, path: String).returns(T.nilable(T::Boolean)) }
      def ignored?(root, path)
        _out, _err, status = Open3.capture3("git", "-C", root.to_s, "check-ignore", "-q", "--", path)
        case status.exitstatus
        when 0 then true
        when 1 then false
        end
      rescue SystemCallError
        nil
      end
    end

    # Writes the managed paths into a project's `.gitignore`.
    class Gitignore
      extend T::Sig

      FILENAME = ".gitignore"

      # @param paths [Array<String>] the repo-relative paths to ensure
      sig { params(paths: T::Array[String]).void }
      def initialize(paths: MANAGED_PATHS)
        @paths = paths
      end

      # Ensure every path is ignored: the ones git already ignores (by any
      # pattern, the user's included) are left alone; the rest are added
      # under dev's marker block — appended to the block when it exists,
      # else as a new block at the end of the file. Outside a git repo the
      # check falls back to a literal line match.
      #
      # @param project_root [Pathname, String]
      # @return [Array<String>] the paths added
      sig { params(project_root: T.any(Pathname, String)).returns(T::Array[String]) }
      def apply(project_root)
        root = Pathname(project_root)
        file = root / FILENAME
        lines = file.file? ? file.read.lines(chomp: true) : []
        added = @paths.reject { |path| covered?(root, path, lines) }
        return [] if added.empty?

        insert(lines, added)
        file.write("#{lines.join("\n")}\n")
        added
      end

      private

      # @param root [Pathname]
      # @param path [String]
      # @param lines [Array<String>] the current .gitignore
      # @return [Boolean]
      sig { params(root: Pathname, path: String, lines: T::Array[String]).returns(T::Boolean) }
      def covered?(root, path, lines)
        ignored = Footprint.ignored?(root, path)
        return ignored unless ignored.nil?

        lines.any? { |line| line.strip == path }
      end

      # Add the paths inside dev's block: right after its last line when the
      # header exists (the block runs to the next blank line or EOF), else as
      # a fresh block after a separating blank line. A block still under the
      # legacy header is the same block; its header is brought current.
      #
      # @param lines [Array<String>] mutated in place
      # @param paths [Array<String>]
      # @return [void]
      sig { params(lines: T::Array[String], paths: T::Array[String]).void }
      def insert(lines, paths)
        header_at = lines.index(HEADER) || lines.index(LEGACY_HEADER)
        if header_at
          lines[header_at] = HEADER
          at = header_at + 1
          at += 1 while at < lines.size && !T.must(lines[at]).strip.empty?
          paths.each_with_index { |path, offset| lines.insert(at + offset, path) }
        else
          lines << "" unless lines.empty? || T.must(lines.last).strip.empty?
          lines << HEADER
          lines.concat(paths)
        end
      end
    end
  end
end
