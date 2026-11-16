---
name: edge-is-as-wide-as-its-target
description: >-
  MUST be used when writing or widening a sudoers rule, a socket grant,
  or any cross-user edge dev converges — or when a job identity "just
  needs" to run one command as another user.
---

# An edge is as wide as what its target can do, not as narrow as its argv

A grant to run one command as another user is a grant to run everything
that command will run: a tool that loads code or data the grantee can
write (brew — formulae are Ruby; a package manager; `docker exec`) is
`ALL` as that user, and the user's own reach (an admin, a docker-group
member) is the edge's reach. So dev converges no edge from the agent
identity into any other: the agent's answer to a missing resource is a
`WANTED:` line for a human, never an escalation; whatever the agent needs
is converged by the identity that owns it, before the agent spawns.

The shape to avoid is the narrowing argument — "exactly this path, NOPASSWD
only", "SETENV widens nothing material", "`docker exec` only" — judged
against the command instead of its target. It was accepted twice (dev#171,
dev#361) because the target was the operator on a Mac, then inherited onto
a root-equivalent target on Linux without a second look.

Wrong — one path, read as one capability:

    ai-agent ALL=(runner) NOPASSWD:SETENV: /home/linuxbrew/.linuxbrew/bin/brew

Right — no edge; the gap is reported, the owner converges it:

    brew install cmake needs the prefix owner (runner) and sudo -n was refused —
    … report the gap rather than escalate: `WANTED: brew install cmake as runner — <why>`

learned-from: dev#569 (the brew edge retired on both platforms; plans#59
§Security, plans#5's warm/trusted invariant, plans#61's rejected
`docker exec` edge).
date: 2026-11-16
