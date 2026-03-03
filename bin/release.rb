#!/bin/sh
# Use PATH ruby (rbenv) if available, fall back to Homebrew Ruby for bootstrapping
if command -v ruby >/dev/null 2>&1; then
  exec ruby -x "$0" "$@"
fi
if command -v brew >/dev/null 2>&1; then
  brew_ruby="$(brew --prefix ruby 2>/dev/null)/bin/ruby"
  if [ -x "$brew_ruby" ]; then
    exec "$brew_ruby" -x "$0" "$@"
  fi
fi
echo "dev: no ruby found. Install rbenv and a Ruby version, or brew install ruby." >&2
exit 1

#!ruby
# frozen_string_literal: true

# Release a new version of dev: bump VERSION + Gemfile.lock, commit, tag,
# push, create GitHub release, compute sha256, update Homebrew formula.
#
# Usage:
#   ./bin/release.rb                 # auto-increments patch (0.2.24 → 0.2.25)
#   ./bin/release.rb 0.3.0           # explicit version
#   ./bin/release.rb "Release notes" # auto-increment with custom notes

require "pathname"
require "json"
require "open3"
require "cli/ui"

CLI::UI::StdoutRouter.enable

DEV_ROOT       = Pathname.new(File.expand_path("..", __dir__))
FORMULA_REPO   = DEV_ROOT.join("..", "homebrew-d3mlabs")
FORMULA_PATH   = FORMULA_REPO.join("Formula", "dev.rb")
VERSION_FILE   = DEV_ROOT.join("VERSION")
GEMFILE_LOCK   = DEV_ROOT.join("Gemfile.lock")
TARBALL_URL    = "https://github.com/d3mlabs/dev/archive/refs/tags/v%s.tar.gz"

def main
  Dir.chdir(DEV_ROOT)
  ensure_clean_tree!
  ensure_on_main!

  current = VERSION_FILE.read.strip
  new_version, notes = parse_args(current)
  commits = commits_since_last_tag

  print_summary(current, new_version, notes, commits)
  abort "Aborted." unless CLI::UI.confirm("Proceed?")
  puts

  CLI::UI::Frame.open("Releasing v#{new_version}") do
    CLI::UI::Spinner.spin("Bumping VERSION #{current} → #{new_version}") do
      bump_version(current, new_version)
    end

    CLI::UI::Spinner.spin("Committing and tagging v#{new_version}") do
      commit_and_tag(new_version, notes)
    end

    CLI::UI::Spinner.spin("Pushing main + tag v#{new_version}") do
      push(new_version)
    end

    CLI::UI::Spinner.spin("Creating GitHub release v#{new_version}") do
      create_release(new_version, notes)
    end

    sha = nil
    CLI::UI::Spinner.spin("Computing tarball sha256") do
      sha = compute_sha256(new_version)
    end

    CLI::UI::Spinner.spin("Updating Homebrew formula") do
      update_formula(new_version, sha)
    end
  end

  CLI::UI.puts("{{v}} {{bold:v#{new_version} released!}}")
  CLI::UI.puts("To update locally: brew update && brew upgrade d3mlabs/d3mlabs/dev")
end

def parse_args(current)
  case ARGV.length
  when 0
    [auto_increment(current), default_notes]
  when 1
    arg = ARGV[0]
    if arg.match?(/\A\d+\.\d+\.\d+\z/)
      [arg, default_notes]
    else
      [auto_increment(current), arg]
    end
  when 2
    [ARGV[0], ARGV[1]]
  else
    abort "Usage: #{$PROGRAM_NAME} [version] [notes]"
  end
end

def auto_increment(version)
  parts = version.split(".").map(&:to_i)
  parts[-1] += 1
  parts.join(".")
end

def default_notes
  log = `git log --oneline #{latest_tag}..HEAD`.strip
  return log unless log.empty?

  "Maintenance release."
end

def latest_tag
  `git describe --tags --abbrev=0 2>/dev/null`.strip
end

def ensure_clean_tree!
  status = `git status --porcelain`.strip
  return if status.empty?

  abort "Working tree is not clean. Commit or stash changes first.\n#{status}"
end

def commits_since_last_tag
  tag = latest_tag
  return [] if tag.empty?

  `git log --oneline #{tag}..HEAD`.strip.lines.map(&:strip)
end

def print_summary(current, new_version, notes, commits)
  CLI::UI::Frame.open("Release: #{current} → #{new_version}", timing: false) do
    CLI::UI.puts("{{bold:Notes:}} #{notes}")
    puts
    if commits.empty?
      CLI::UI.puts("{{bold:Commits:}} (none since #{latest_tag})")
    else
      CLI::UI.puts("{{bold:Commits since #{latest_tag}:}}")
      commits.each { |c| CLI::UI.puts("  #{c}") }
    end
    puts
    CLI::UI.puts("{{bold:Steps:}}")
    CLI::UI.puts("  1. Bump VERSION + Gemfile.lock")
    CLI::UI.puts("  2. Commit + tag v#{new_version}")
    CLI::UI.puts("  3. Push main + tag to origin")
    CLI::UI.puts("  4. Create GitHub release")
    CLI::UI.puts("  5. Update Homebrew formula + push")
  end
  puts
end

def ensure_on_main!
  branch = `git branch --show-current`.strip
  return if branch == "main"

  abort "Must be on main branch (currently on #{branch})."
end

def run!(*cmd)
  out, err, status = Open3.capture3(*cmd)
  raise "#{cmd.join(" ")} failed: #{err}" unless status.success?

  out
end

def bump_version(current, new_version)
  VERSION_FILE.write("#{new_version}\n")

  lock = GEMFILE_LOCK.read
  GEMFILE_LOCK.write(lock.gsub("dev (#{current})", "dev (#{new_version})"))
end

def commit_and_tag(version, notes)
  run!("git", "add", "VERSION", "Gemfile.lock")
  run!("git", "commit", "-m", "Bump version to #{version}\n\n#{notes}")
  run!("git", "tag", "v#{version}")
end

def push(version)
  run!("git", "push", "origin", "main")
  run!("git", "push", "origin", "v#{version}")
end

def create_release(version, notes)
  run!("gh", "release", "create", "v#{version}",
    "--title", "v#{version}", "--notes", notes)
end

def compute_sha256(version)
  url = format(TARBALL_URL, version)
  tarball = "/tmp/dev-#{version}.tar.gz"
  run!("curl", "-fSL", "-o", tarball, url)
  `shasum -a 256 #{tarball}`.split.first
end

def update_formula(version, sha)
  abort "Homebrew tap not found at #{FORMULA_REPO}" unless FORMULA_PATH.exist?

  formula = FORMULA_PATH.read
  formula.gsub!(/version "[\d.]+"/, "version \"#{version}\"")
  formula.gsub!(%r{url "https://github\.com/d3mlabs/dev/archive/refs/tags/v[\d.]+\.tar\.gz"},
    "url \"#{format(TARBALL_URL, version)}\"")
  formula.gsub!(/sha256 "[a-f0-9]+"/, "sha256 \"#{sha}\"")
  FORMULA_PATH.write(formula)

  Dir.chdir(FORMULA_REPO) do
    run!("git", "add", "Formula/dev.rb")
    run!("git", "commit", "-m", "dev: #{version}")
    run!("git", "push", "origin", "main")
  end
end

main
