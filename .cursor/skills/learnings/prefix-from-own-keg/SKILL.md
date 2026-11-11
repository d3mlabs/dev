---
name: prefix-from-own-keg
description: >-
  MUST be used when dev needs the Homebrew prefix or any other fact about
  where it is installed (the Cellar, a sibling keg, the deployment's
  etc/dev payload), or when a job on a runner service behaves as if dev
  were unconfigured while a login shell on the same host shows it is.
---

# Install facts come from dev's own path, never from the environment

Where dev is installed is a fact about dev, not about the caller's
environment: dev is a brew keg, so `File.realpath` of its root
(`Dev::Version::ROOT`, `<prefix>/Cellar/dev-core/<v>/libexec/dev`) names
the prefix with no env at all. `Settings.brew_prefix` is the one
resolution — `HOMEBREW_PREFIX` is an override for the odd layout, never
the source — and a source checkout, which sits in no Cellar, has no
prefix and so no system layer. Login-shell state (`/etc/profile.d`
exports, `brew shellenv`) is absent in every runner service (systemd,
launchd) and in `sudo -u`; a probe of standard directories finds
`/usr/local` on every Linux host whether brew is there or not.

Wrong — env first, then a guess that is true on every Linux host:

    ENV["HOMEBREW_PREFIX"] ||
      ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"].find { |p| Dir.exist?(p) }

Right — the keg dev runs from, the env as the override:

    override = ENV["HOMEBREW_PREFIX"]
    return override if override && !override.empty?
    cellar = Pathname(File.realpath(root)).ascend.find { |dir| dir.basename.to_s == "Cellar" }
    cellar&.dirname&.to_s

The symptom is a job that reports dev unconfigured (`no knowledge repo
configured`, a self-update aimed at dev-core instead of the deployment)
while `sudo -iu runner dev config list` on the same host shows every key
`(system)`: the login shell exported what the service never had.

learned-from: dev#568 (the box's first `/build`, 2026-11-11 — every Linux
job ran without the org identity).
date: 2026-11-11
