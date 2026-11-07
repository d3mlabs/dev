---
name: status-probes-never-prompt
description: >-
  MUST be used when adding a fact to `dev runner status` (or any
  inspect-only report) that is read across a user boundary — as the
  runner user, the agent user, or from a file the operator cannot read —
  or when a status line's `[!!]` is reported as wrong on a working host.
---

# Inspect-only probes never prompt; what they cannot see is `[??]`, not `[!!]`

An inspector (`Dev::RunnerStatus`) runs every cross-user probe
non-interactively (`sudo -n`, `RunnerUser#probe_argv`) and gates the
section on a cheap sentinel (`sudo -n -u <user> true`): a refusal is a
fact to report, never a prompt swallowed into "absent". A fact the
operator's account cannot observe is reported as unknown with the
by-hand command that can tell — never as the finding whose remedy would
undo a working state. A `[!!]` that is wrong once is ignored when it is
right; the report's whole value is trust.

Wrong — the login probe's failure read as "no login", remedy included:

    unless @executor.quiet?(*identity.sudo_argv("gh", "auth", "status"))
      line(false, "no gh login — `#{identity.login_command}`")  # sudo refused

Right (dev#348) — gate first, then probe, each with `-n`:

    unless @executor.quiet?(*identity.probe_argv("true"))
      unknown("gh login: cannot tell as #{@runner_user} ... — check with `#{identity.status_command}`")
      return false
    end
    unless @executor.quiet?(*identity.probe_argv("gh", "auth", "status"))
      line(false, "no gh login — `#{identity.login_command}`")

Same class as the sudoers-edge probes (dev#365): the drop-in is
root-owned, so the edges are read the way a job exercises them (`sudo
-n`), and a refusal of the first probe is the finding. Register, which
holds a sudo session, keeps interactive `sudo_argv`.

learned-from: dev#348 (a cached-session-less operator saw `[!!] no gh
login` on a logged-in runner user), second instance after dev#365
date: 2026-11-07
