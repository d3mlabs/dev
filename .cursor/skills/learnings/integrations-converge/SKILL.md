---
name: integrations-converge
description: >-
  MUST be used when an Integration#install_all verifies installed state
  against the lock, or when an error message tells a human to run a
  command that converges the machine — the install path owns that step.
---

# An integration converges to the lock; it does not report drift to a human

A `Dev::Deps` integration's install path must leave the machine at what
the lock pins, for every state it can start from — absent, present at
another version, newer, older — because an ephemeral runner booting a
checkpoint has no human to finish the job. Verification stays (the lock
only means something if the result is checked), but it runs *after*
convergence; a remediation that is a command dev could run itself is a
missing convergence step, not an error message. Human remediations are
decisions dev cannot make: re-lock (`dev deps update`), declare a target.

Wrong — install only when absent, then hand the human a shell command:

    run_brew_install(spec) unless brew_installed?(formula)
    raise VersionMismatchError, "… if this machine is behind, `brew upgrade #{formula}`"

Right (dev#350) — a keg at another version is brought to the lock first
(the exact bottle the lock records, else a refreshed `brew upgrade`), and
the error that survives names the one remediation that needs a human:

    converge!(dep, formula, locked, installed) unless @pin_taps
    return if installed_versions(formula).include?(locked)
    raise VersionMismatchError, "… if brew's formula moved on, run `dev deps update`"

The lock usually carries what convergence needs (ADR-0004's per-platform
hash and link made the exact brew bottle fetchable with no index); when
it does not, that is a lock-shape gap to fix at `dev deps update`, not a
reason to ask the human.

learned-from: dev#350 — cellbound-3d's warm checkpoint failed `dev up`
on two brew pins that had moved; gh, gems and pip installed the
difference per run, brew verified and stopped.
date: 2026-10-29
