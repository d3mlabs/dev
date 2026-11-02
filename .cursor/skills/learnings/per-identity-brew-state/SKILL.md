---
name: per-identity-brew-state
description: >-
  MUST be used when a host bootstrap (RunnerUser, AgentBootstrap) sets up
  brew for an identity, when a new per-user brew behaviour lands (tap
  trust, auto-update, anything under ~/.homebrew), or when a job identity's
  `dev deps` is refused a formula the operator's brew loads fine.
---

# Brew state is per identity, and a host has several

Homebrew keeps some state per *invoking user*, not per prefix: tap trust
(`~/.homebrew/trust.json`; Homebrew 7 loads nothing from an untrusted
third-party tap), auto-update behaviour under a non-owner uid (dev#372).
A host runs brew as more than one identity — the operator, the Linux
runner user, the macOS agent user — so converging such state for one
identity leaves the others refused, and the refusal surfaces far away: a
job's `dev deps` failing, or an agent working around it with a mid-run
host mutation. Every identity's bootstrap converges every per-user brew
surface, through one shared step rather than a copy per bootstrap.

Wrong — the Linux path trusts the tap for its user; the macOS path
converges user, group, sudoers, shared root and nothing of brew's:

    def converge!           # AgentBootstrap
      ensure_agent_user!; ensure_group!; ensure_sudoers!; ensure_shared_root!
    end

Right — one `TapTrust` step; each bootstrap hands it only what differs,
how to run as its identity:

    TapTrust.new(user: agent, brew:, tap:, out:,
      run_as_user: ->(argv) { @as_agent.run(*argv) }).trust!

Cue: a tap formula resolves for the operator and is "refused from
untrusted tap" for the job user (`sudo -iu <user> brew info <formula>`).
A new per-user brew edge lands in *both* bootstraps the day it lands.
learned-from: dev#374 (the agent user's untrusted tap; a `/build` pass ran
`brew trust` itself), the second per-user brew surface after dev#372.
date: 2026-11-01
