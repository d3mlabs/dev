# Architecture Decision Records (ADR log)

The record of dev's foundational decisions: the ones that shape how every consumer runs dev, and that a change would have to reopen rather than quietly revise. Each ADR is immutable once `Accepted`; a revision supersedes it with a new ADR. The README describes what dev does today; this log records why it is that way and what was rejected.

Format: Context → Decision → Consequences → Rejected. Status: `Accepted` unless noted.

---

## ADR-0001 — dev is live infrastructure

**Status:** Accepted. Litigated in [dev#218](https://github.com/d3mlabs/dev/issues/218) — the thread to reopen before changing any of it.

**Context.** dev runs on workstations, on self-hosted runners, in hosted CI jobs, and in the build containers it orchestrates. Each place dev runs is a place a stale dev can run. Hosts already converged on the latest release on every `dev up` ([b835291](https://github.com/d3mlabs/dev/commit/b835291) removed the last self-update throttle so a fix propagates on the next `dev up`), but the build-container image bootstrap left a `brew install dev-core` in the image layer ([fcdbb69](https://github.com/d3mlabs/dev/commit/fcdbb69) and before) — never run by anyone, but a frozen copy that *could* be run by accident, and a permanent question of which dev an image contains.

**Decision.**

- **dev is live infrastructure, not a pinned dependency.** Projects declare no dev version; every machine runs the latest release from the tap. Hosts converge on `dev up`. The rule made for hosts is the rule for every place dev runs.
- **Backward compatibility is the only contract.** Because consumers never pin, a release must keep reading every project artifact its predecessors wrote: `dev.yml`, `dependencies.rb`, and the lockfiles (the reader still accepts the legacy flat lock format for exactly this reason). A change the previous release's files cannot survive is a breaking change and is released as one.
- **The build container is the dependency environment; the image is not a copy of dev.** Image builds install their toolchain with `dev deps install --group build --integration brew` from `build-deps.lock` — the same command, reading the same lock, as the host — and then uninstall dev-core (`bin/docker-install-build-deps.sh`). The tool that ran the install leaves; only what it installed stays. The image's answer to "which dev does it contain" is "none".
- **Containers match the orchestrator.** Today no dev runs inside a build container: the host's dev orchestrates (`docker exec`) and the container runs the project's commands. When dev does run inside (dev#218's remaining milestones put `dev deps install` where its deps are consumed), the host provisions dev-core at its own exact version into the container's writable layer at container up — one version per host, host and container alike — and hosted jobs with no orchestrating host get the latest release, like a fresh workstation. The inside dev knows it is inside (`DEV_INSIDE_CONTAINER=1`, set by the host on every container it creates) and so never self-updates: the host is the only writer of the container's dev.
- **The writable layer is ephemeral by design.** A persistent container is per checkout and per image tag (`dev-<image>-<workspace_id>-<tag>`); anything that must survive a rebuild (installed deps, caches) lives in the data root, never in the layer.

**Consequences.** No per-repo dev version to bump. A release is the only unit of change consumers see, so release discipline (backward-compatible readers, breaking changes called out) carries the whole contract. Image builds depend on the tap at build time (to install the dev that installs the toolchain) and never on a dev inside the image afterwards. The README's "dev is live infrastructure" section is the operative summary of this record.

**Rejected.** Pinning a dev version per image — reintroduces the stale-dev-in-the-image class this record exists to end, plus a bump chore per repo per release. `brew upgrade dev-core` at job start on a dev frozen into the image — a second, slower update path for a copy that should not exist.
