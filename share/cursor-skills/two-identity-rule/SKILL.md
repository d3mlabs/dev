---
name: two-identity-rule
description: >-
  MUST be used when writing or copying a workflow step that runs dev inside
  a job — `dev up`, `dev deps install`, `uses: d3mlabs/dev/up@main` — or
  when a job fails with `Permission denied @ dir_s_mkdir - /var/lib/dev`.
---

# Two identities run dev in a job; each has one verb

A job's own identity — the runner user on a GitHub-hosted runner or on a
self-hosted box — owns the host it runs on and runs `dev up`: it
provisions the data root under its own sudo, converges the host tooling
and installs the lock, cold or warm, every job; in a workflow that step
is `uses: d3mlabs/dev/up@main`. A non-owning identity — the agent user
ai-flow spawns inside a job, a process inside a container the host
provisioned — runs `dev deps install`: the per-checkout install against
a data root someone else converged, with no host work in it.

Pick the verb by the identity that runs it, not by the precedent you are
copying. `dev deps install` as the runner user on a cold runner dies with
`Permission denied @ dir_s_mkdir - /var/lib/dev` because that verb never
provisions the data root; the cure is the other verb — never a permission
grant, never teaching `dev deps install` to do host work.

Wrong — the runner user's step copied from the agent user's:

    - run: dev deps install        # runner user, cold hosted runner

Right — each identity on its own verb:

    - uses: d3mlabs/dev/up@main    # runner user: converge the host, install the lock
    # later, inside the job, ai-flow's agent user runs `dev deps install`
    # in its checkout — a host the runner user already converged

The recipe behind the action: https://github.com/d3mlabs/dev/blob/HEAD/docs/runners.md ("The hosted recipe").

learned-from: d3mlabs/dev#545 — rubocop-d3mlabs's release.yml copied the
agent user's `dev deps install` for the runner user and failed cold.
date: 2026-11-16
