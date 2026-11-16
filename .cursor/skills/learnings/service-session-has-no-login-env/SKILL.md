---
name: service-session-has-no-login-env
description: >-
  MUST be used when code reads anything a login session exports —
  WSL_DISTRO_NAME, WSL_INTEROP, HOMEBREW_PREFIX, PATH, a profile.d export
  — or when a `dev` command dies or reads red in a job while the same
  command in a shell on the same host is fine.
---

# A job's session is a service's, not a login shell's

A job on a runner host runs under systemd / launchd / `sudo -u`: no
`/init` login, no `/etc/profile.d`, no interop socket, no distro name,
no brew on PATH. Anything a login session *exports* is absent there, so
a fact must come from the host (procfs, the keg's realpath, a stat) or
be demanded lazily and only on the path a login session alone can take —
after the probe that shows the session can ask. A fact the job's identity
cannot read is `?`, never `✗` and never a crash.

Wrong — a name the login env carries, demanded before the check that it
is a login session:

    task = wsl.task                       # WSL_DISTRO_NAME → raises in a service
    return unknown(...) if status.keepalive.nil?

Right — the check first; the login-only name only on the path that has it:

    return unknown("logon keepalive#{name_if_known}: cannot tell …") if status.keepalive.nil?
    task = wsl.task

Instances: dev#564 (the CLI built the keepalive task at startup — every
`dev` on the box died in jobs), dev#568 (brew prefix from the shell —
`one-brew-prefix-resolution`), dev#571 (`runner status` named the task
before the interop check — `--check` could not finish in a service).

learned-from: dev#571's first live `--check` on the box, 2026-11-16 —
the third place a login-session export was read from a service.
date: 2026-11-16
