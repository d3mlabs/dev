---
name: one-brew-prefix-resolution
description: >-
  MUST be used when code needs the Homebrew prefix or brew's binary, is
  about to read HOMEBREW_PREFIX, PATH, or `brew --prefix`, or when a job
  on a runner service behaves as if dev were unconfigured while a login
  shell on the same host shows it is.
---

# One brew-prefix resolution, from facts on disk — never from the shell

`Settings.brew_prefix` is the single answer, and every brew-facing part
of dev reads it (`RunnerUser.brew_path` for the binary): `HOMEBREW_PREFIX`
as the override; else the prefix dev's own keg sits in
(`<prefix>/Cellar/<formula>/<v>/libexec/dev`, by realpath); else the
standard location whose `bin/brew` is executable; else nil, a machine
without brew. Two rules fall out. Shell state — `HOMEBREW_PREFIX` from
`/etc/profile.d`, brew on PATH, `brew --prefix` — is absent in every
service (systemd, launchd, `sudo -u`), so it may override but never be
the source. And a probe tests the fact that places brew: `/usr/local`
*exists* on every Linux host; `/usr/local/bin/brew` does not.

Wrong — a fourth opinion beside the resolution, true on every host:

    ENV.fetch("HOMEBREW_PREFIX") { RUBY_PLATFORM.include?("arm64") ? "/opt/homebrew" : "/usr/local" }
    ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"].find { |p| Dir.exist?(p) }
    Open3.capture3("brew", "--prefix")

Right — read the one resolution, injectable for tests:

    def initialize(brew_prefix: Settings.brew_prefix)

The symptom of a second resolver is a job reporting dev unconfigured
(`no knowledge repo configured`, a self-update aimed at dev-core) while
`sudo -iu runner dev config list` on the same host shows every key
`(system)`: the login shell exported what the service never had.

learned-from: dev#568 (the box's first `/build`, 2026-11-11 — four
resolvers, every Linux job without the org identity; fixed in dev#578).
date: 2026-11-11
