---
name: state-kind-before-identity-rule
description: >-
  MUST be used when writing a rule keyed on who owns a prefix, a tree or a
  keg — a skip for non-owners, an escalation, a refusal, a WANTED posture
  — or when a `dev up` by one identity fails on state another identity
  "owns".
---

# Name the kind of state before the identity rule that governs it

dev's host state and a checkout's state have different convergers, and
no ownership fact tells them apart. Host state (dev's self-update, the
org Brewfile, the prefix's kegs as a whole) is the prefix owner's: on a
Linux build host the jobs converge it on their next run, and anyone
else's `dev up` skips it silently. Project state (`dependencies.rb` pins,
the project's gems, its venv) is whoever runs `dev up` in that checkout:
a human converges it through the owner with their own password, the
agent never converges it (the dispatcher does, before the spawn). A rule
written from "does the caller own the prefix?" alone will apply one
kind's answer to the other.

Wrong — a host-state skip read as the rule for every brew write by a
non-owner, so the operator's checkout pins died on `sudo -n`:

    Rejected: `sudo -u runner brew …` from `dev up` — the operator should
    not escalate to converge another user's tree; the jobs do that.

Right — the state is classified first, and each kind keeps its converger:

    HostService#converge_tooling   # host half: skipped for a non-owner, the jobs' to run
    BrewIntegration#escalation     # the checkout's pins: `sudo -u <owner>` at a TTY, `-n` headless

The same shape put the project's gem home in the owner's keg (dev#294)
and the agent's pins behind a brew edge (dev#171 → dev#569): each time
the fix was to ask whose state it was, not whose prefix.

learned-from: dev#570 (dev#337 Decision 3 amended), with dev#294 and
dev#569 as the earlier instances.
date: 2026-11-16
