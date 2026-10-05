#!/bin/sh
# Use PATH ruby (rbenv) if >= 3.1, fall back to Homebrew Ruby for bootstrapping.
# dev uses Ruby 3.1+ syntax (e.g. hash literal value omission).
if command -v ruby >/dev/null 2>&1; then
  if ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1") ? 0 : 1)' 2>/dev/null; then
    exec ruby -x "$0" "$@"
  fi
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
#   ./bin/release.rb --yes           # skip the confirmation (non-interactive runs)
#
# The tap clone is checked and fast-forwarded before anything is bumped, and
# a run whose dev half already landed (HEAD tagged v<VERSION>) resumes at the
# push instead of bumping again — a retry finishes the release, it does not
# cut a second one.

require "pathname"
require "json"
require "open3"
require "cli/ui"

CLI::UI::StdoutRouter.enable

DEV_ROOT       = Pathname.new(File.expand_path("..", __dir__))
FORMULA_REPO   = DEV_ROOT.join("..", "homebrew-d3mlabs")
# Two formulas version in lockstep off the same release tarball: dev-core (the generic tool) and dev (the d3mlabs
# deployment: org config + a dependency on dev-core).
FORMULA_PATHS  = [
  FORMULA_REPO.join("Formula", "dev-core.rb"),
  FORMULA_REPO.join("Formula", "dev.rb"),
].freeze
VERSION_FILE   = DEV_ROOT.join("VERSION")
GEMFILE_LOCK   = DEV_ROOT.join("Gemfile.lock")
TARBALL_URL    = "https://github.com/d3mlabs/dev/archive/refs/tags/v%s.tar.gz"

def main
  Dir.chdir(DEV_ROOT)
  ensure_clean_tree!
  ensure_on_main!
  ensure_tap_ready!

  # --yes skips the interactive confirmation, which would otherwise hang a
  # piped or backgrounded run waiting for input it can never receive.
  assume_yes = !ARGV.delete("--yes").nil?

  current = VERSION_FILE.read.strip
  return resume(current, assume_yes) if resumable?(current)

  new_version, notes = parse_args(current)
  commits = commits_since_last_tag

  print_summary(current, new_version, notes, commits)
  abort "Aborted." unless assume_yes || CLI::UI.confirm("Proceed?")
  puts

  CLI::UI::Frame.open("Releasing v#{new_version}") do
    step("Bumping VERSION #{current} → #{new_version}") do
      bump_version(current, new_version)
    end

    step("Committing and tagging v#{new_version}") do
      commit_and_tag(new_version, notes)
    end

    publish(new_version, notes)
  end

  released(new_version)
end

# The steps after the local commit + tag, each idempotent so a resumed run
# can replay them: push is a no-op for refs already on origin, the release
# is created only when missing, and the formula is rewritten from the tag's
# tarball either way.
def publish(version, notes)
  step("Pushing main + tag v#{version}") do
    push(version)
  end

  step("Creating GitHub release v#{version}") do
    create_release(version, notes)
  end unless release_exists?(version)

  sha = nil
  step("Computing tarball sha256") do
    sha = compute_sha256(version)
  end

  step("Updating Homebrew formula") do
    update_formula(version, sha)
  end
end

# A run whose dev half landed but whose tap half did not: HEAD already carries
# the v<VERSION> tag and the formula does not reference that tarball yet.
# Bumping again here is how 0.2.99 became a second, empty 0.2.100 — the tap
# push had failed on a stale clone and the retry started over.
def resumable?(version)
  `git tag --points-at HEAD`.split.include?("v#{version}") && !formula_at?(version)
end

def formula_at?(version)
  url = format(TARBALL_URL, version)
  FORMULA_PATHS.all? { |path| path.read(encoding: "UTF-8").include?(url) }
end

def resume(version, assume_yes)
  notes = `git log -1 --format=%b HEAD`.strip
  CLI::UI.puts("v#{version} is already tagged on HEAD and the tap is behind it — resuming at the push, no bump.")
  abort "Aborted." unless assume_yes || CLI::UI.confirm("Proceed?")
  puts

  CLI::UI::Frame.open("Finishing v#{version}") do
    publish(version, notes)
  end

  released(version)
end

def released(version)
  CLI::UI.puts("{{v}} {{bold:v#{version} released!}}")
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

# The formula push is the last step and the one that failed on 0.2.99: a tap
# clone behind origin cannot push. Everything the formula step needs — clone
# present, clean, on main, fast-forwarded to origin, formulas in place — is
# checked here, before the dev side has bumped anything.
def ensure_tap_ready!
  abort "Homebrew tap clone not found at #{FORMULA_REPO}" unless FORMULA_REPO.join(".git").exist?

  Dir.chdir(FORMULA_REPO) do
    status = `git status --porcelain`.strip
    abort "Tap clone #{FORMULA_REPO} is not clean. Commit or stash changes first.\n#{status}" unless status.empty?

    branch = `git branch --show-current`.strip
    abort "Tap clone #{FORMULA_REPO} must be on main (currently on #{branch})." unless branch == "main"

    begin
      run!("git", "fetch", "-q", "origin", "main")
      run!("git", "merge", "-q", "--ff-only", "origin/main")
    rescue RuntimeError => e
      abort "Tap clone #{FORMULA_REPO} cannot fast-forward to origin/main: #{e.message}"
    end
  end

  FORMULA_PATHS.each do |formula_path|
    abort "Homebrew formula not found at #{formula_path}" unless formula_path.exist?
  end
end

def release_exists?(version)
  _, _, status = Open3.capture3("gh", "release", "view", "v#{version}")
  status.success?
end

# One release step under a spinner, aborting the whole release when it fails.
# Spinner.spin swallows the block's exception and only reports it — without
# the abort, a failed push once cascaded into the formula publishing a tag
# that never reached GitHub (v0.2.73), breaking brew installs until hand-fixed.
def step(title, &block)
  return if CLI::UI::Spinner.spin(title, &block)

  abort "Release aborted: '#{title}' failed. Fix the issue, then finish the remaining steps manually."
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
  FORMULA_PATHS.each do |formula_path|
    # Read as UTF-8 explicitly: the formulas have non-ASCII bytes (e.g. an em-dash in a comment), and when release.rb
    # runs under a non-UTF-8 locale (such as a piped, login-less subshell) Ruby's default external encoding is
    # US-ASCII, which makes the sub below raise "invalid byte sequence in US-ASCII".
    formula = formula_path.read(encoding: "UTF-8")

    # Update the package url + its sha256 together, anchored to the github archive url. dev-core also carries one
    # `sha256` line per vendored-gem `resource`; those are immutable per gem version and must NOT change on a dev
    # release. (A prior gsub over every `sha256 "..."` replaced the resource checksums too, with the tarball sha,
    # silently corrupting them — clean installs then failed resource verification.) Matching the url+sha as a pair
    # keeps it surgical.
    pattern = %r{(url "https://github\.com/d3mlabs/dev/archive/refs/tags/v)[\d.]+(\.tar\.gz"\n\s+sha256 ")[0-9a-f]+(")}
    updated = formula.sub(pattern) { "#{$1}#{version}#{$2}#{sha}#{$3}" }
    abort "Could not find the package url+sha256 to update in #{formula_path}" if updated == formula

    formula_path.write(updated)
  end

  Dir.chdir(FORMULA_REPO) do
    run!("git", "add", *FORMULA_PATHS.map { |path| path.relative_path_from(FORMULA_REPO).to_s })
    run!("git", "commit", "-m", "dev: #{version}")
    run!("git", "push", "origin", "main")
  end
end

main
