# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "learnings/layout"
require_relative "plan/workspace"
require_relative "skills/layout"

module Dev
  # What dev materializes into an adopting repo's checkout that must never
  # be committed — and the one mechanism that makes "gitignored" a fact
  # rather than a README claim. Each producer owns the ignore line for the
  # path it materializes (the constant sits beside the path it covers, so
  # the two cannot drift); this module collects them, writes them into the
  # repo's `.gitignore` under one marker block, and checks them.
  #
  # Idempotency is per path, judged by git itself (`git check-ignore`): a
  # path the user already covers with their own pattern is left alone, a
  # missing one is added inside dev's block. Lines the user wrote are never
  # moved or rewritten.
  module Footprint
    extend T::Sig

    # The comment heading dev's block in a repo's .gitignore.
    HEADER = "# dev-managed agent links — rematerialized by `dev up` / `dev deps install` / `dev plan`, never committed"

    # Every path dev materializes into a project, from its owner.
    MANAGED_PATHS = T.let(
      [
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

      # Print one warning per path git does not ignore, on the given stream.
      #
      # @param out [IO, StringIO]
      # @param project_root [Pathname, String]
      # @param paths [Array<String>]
      # @return [void]
      sig { params(out: T.any(IO, StringIO), project_root: T.any(Pathname, String), paths: T::Array[String]).void }
      def warn_missing(out, project_root, paths)
        missing(project_root, paths).each do |path|
          out.puts "dev: warning: #{path} is not gitignored — #{REPAIR_HINT}."
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
      # a fresh block after a separating blank line.
      #
      # @param lines [Array<String>] mutated in place
      # @param paths [Array<String>]
      # @return [void]
      sig { params(lines: T::Array[String], paths: T::Array[String]).void }
      def insert(lines, paths)
        header_at = lines.index(HEADER)
        if header_at
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
