---
name: another-projects-facts-are-declarations
description: >-
  MUST be used when about to write another repo's name, label vocabulary,
  runner group, workflow path, user name or CLI binary into dev as a
  constant, a builtin or a flag — or when naming a convergence step for
  the one consumer it was built for.
---

# Another project's facts enter dev as its dev.yml declaration, never as constants

A fact that is one project's — ai-flow's agent labels, its `ai-flow` group
and workflow paths, the `ai-agent` user, the `cursor-agent` binary —
changes on that project's schedule, and a second project with the same
shape (a GPU farm with its own group and job user) cannot say so through a
constant. The project declares the fact in its own `dev.yml`
(`runner_roles:` — `labels`, `group`, `workflows`, `job_identity`); dev
holds the shape (a role, a group contract, a job identity) and binds the
declaration where it is read; anything derivable (a pin's ref, from the
project's `VERSION` series) is derived, never typed. A migration keeps the
old spelling as a one-release alias that warns and names the replacement,
in one module deleted whole.

Wrong — dev carries the consumer's facts, named for the consumer:

    AI_FLOW_AGENT_LABELS = %w[ai-ask ai-edit ai-split ai-build ai-learn]
    class AgentBootstrap   # converges `ai-agent`; warns when `cursor-agent` is missing

Right — the consumer declares; dev binds:

    runner_roles: { agent: { labels: [...], group: ai-flow, workflows: [...], job_identity: ai-agent } }
    RunnerRole::Declaration#bind(repo:, version:)   # pins at v<major>; JobIdentity.for_host(user:)

Exception: host-side contract names the other project *reads* (an env
key, a drop-in file name) are an interface and stay stable.

learned-from: dev#657 (plans#76) — `LabelContracts::AI_FLOW_*`, the `agent`/
`orchestrator` builtins, `--ai-flow`, `--agent-user` and `AgentBootstrap`'s
CLI lookup, added across dev#470 and dev#546, removed together.
date: 2026-11-20
