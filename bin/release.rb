#!/usr/bin/env ruby
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
  confirm!

  bump_version(current, new_version)
  commit_and_tag(new_version, notes)
  push(new_version)
  create_release(new_version, notes)
  sha = compute_sha256(new_version)
  update_formula(new_version, sha)

  puts
  puts "✅ v#{new_version} released!"
  puts "   brew update && brew upgrade d3mlabs/d3mlabs/dev"
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
  puts "┌─────────────────────────────────────────"
  puts "│ Release: #{current} → #{new_version}"
  puts "│"
  puts "│ Notes: #{notes}"
  puts "│"
  if commits.empty?
    puts "│ Commits: (none since #{latest_tag})"
  else
    puts "│ Commits since #{latest_tag}:"
    commits.each { |c| puts "│   #{c}" }
  end
  puts "│"
  puts "│ Steps:"
  puts "│   1. Bump VERSION + Gemfile.lock"
  puts "│   2. Commit + tag v#{new_version}"
  puts "│   3. Push main + tag to origin"
  puts "│   4. Create GitHub release"
  puts "│   5. Update Homebrew formula + push"
  puts "└─────────────────────────────────────────"
  puts
end

def confirm!
  $stdout.write("Proceed? [y/N] ")
  $stdout.flush
  answer = $stdin.gets&.strip&.downcase
  abort "Aborted." unless answer == "y"
  puts
end

def ensure_on_main!
  branch = `git branch --show-current`.strip
  return if branch == "main"

  abort "Must be on main branch (currently on #{branch})."
end

def bump_version(current, new_version)
  puts "  Bumping VERSION #{current} → #{new_version}"
  VERSION_FILE.write("#{new_version}\n")

  lock = GEMFILE_LOCK.read
  GEMFILE_LOCK.write(lock.gsub("dev (#{current})", "dev (#{new_version})"))
end

def commit_and_tag(version, notes)
  puts "  Committing and tagging v#{version}"
  system("git", "add", "VERSION", "Gemfile.lock", exception: true)
  system("git", "commit", "-m", "Bump version to #{version}\n\n#{notes}", exception: true)
  system("git", "tag", "v#{version}", exception: true)
end

def push(version)
  puts "  Pushing main + tag v#{version}"
  system("git", "push", "origin", "main", exception: true)
  system("git", "push", "origin", "v#{version}", exception: true)
end

def create_release(version, notes)
  puts "  Creating GitHub release v#{version}"
  system("gh", "release", "create", "v#{version}",
    "--title", "v#{version}", "--notes", notes, exception: true)
end

def compute_sha256(version)
  puts "  Computing tarball sha256"
  url = format(TARBALL_URL, version)
  tarball = "/tmp/dev-#{version}.tar.gz"
  system("curl", "-fSL", "-o", tarball, url, exception: true)
  sha = `shasum -a 256 #{tarball}`.split.first
  puts "  sha256: #{sha}"
  sha
end

def update_formula(version, sha)
  puts "  Updating Homebrew formula"
  abort "Homebrew tap not found at #{FORMULA_REPO}" unless FORMULA_PATH.exist?

  formula = FORMULA_PATH.read
  formula.gsub!(/version "[\d.]+"/, "version \"#{version}\"")
  formula.gsub!(%r{url "https://github\.com/d3mlabs/dev/archive/refs/tags/v[\d.]+\.tar\.gz"},
    "url \"#{format(TARBALL_URL, version)}\"")
  formula.gsub!(/sha256 "[a-f0-9]+"/, "sha256 \"#{sha}\"")
  FORMULA_PATH.write(formula)

  Dir.chdir(FORMULA_REPO) do
    system("git", "add", "Formula/dev.rb", exception: true)
    system("git", "commit", "-m", "dev: #{version}", exception: true)
    system("git", "push", "origin", "main", exception: true)
  end
end

main
