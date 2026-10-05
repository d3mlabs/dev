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
- **Containers match the orchestrator.** The host's dev owns the container's lifecycle, and on every `dev up` / `dev container up` it converges the persistent container's dev-core to its own exact version (`dev version` inside equals outside): one version per host, host and container alike, re-synced after a host upgrade with no manual step. The exact version is not "latest from the tap" — the tap only carries the latest formula, so the install checks the tap out at the commit whose `dev-core` formula shipped that version (`bin/container-provision-dev.sh`) and never falls back to latest silently. Hosted jobs with no orchestrating host get the latest release, like a fresh workstation. The inside dev knows it is inside (`DEV_INSIDE_CONTAINER=1`, set by the host on every container it creates) and so never self-updates: the host is the only writer of the container's dev.
- **The writable layer is ephemeral by design.** A persistent container is per checkout and per image tag (`dev-<image>-<workspace_id>-<tag>`); anything that must survive a rebuild (installed deps, caches, the container's Ruby and gems) lives in the data root, never in the layer.

**Consequences.** No per-repo dev version to bump. A release is the only unit of change consumers see, so release discipline (backward-compatible readers, breaking changes called out) carries the whole contract. Image builds depend on the tap at build time (to install the dev that installs the toolchain) and never on a dev inside the image afterwards. The README's "dev is live infrastructure" section is the operative summary of this record.

**Rejected.** Pinning a dev version per image — reintroduces the stale-dev-in-the-image class this record exists to end, plus a bump chore per repo per release. `brew upgrade dev-core` at job start on a dev frozen into the image — a second, slower update path for a copy that should not exist.

---

## ADR-0002 — Dependencies install where they are consumed

**Status:** Accepted. Milestone 5 of [dev#218](https://github.com/d3mlabs/dev/issues/218).

**Context.** With dev running inside the build container (ADR-0001), one `dev deps install` on the host cannot serve both sides. Gems made it concrete: a `bundle install` on a Mac produces native extensions for darwin, which a Linux container cannot load, and the container has no rbenv Ruby to install them against. File artifacts (`gh` releases, Steam apps, ficsit mods) have the opposite shape: fetched once, platform-neutral or already platform-keyed, and readable from either side through the shared data root.

**Decision.** Each integration type has a scope (`lib/dev/deps/registry.rb`: `HOST`, `CONTAINER` or `BOTH`). The host's `dev deps install` runs the host-scoped types; `dev container up` then runs `dev deps install` inside the container, where the container-scoped types run against the container's own Ruby — a `ruby-build` tree in the shared artifact store, not an rbenv one, activated by a shadowenv guard that only fires behind `DEV_INSIDE_CONTAINER`. `bundler`, `brew` and `cask` are `BOTH` (each side gets its own bundle against its own Ruby); everything else is `HOST`, and the container reads those artifacts through the store. The host-side hygiene hooks (gem skill links, learnings sync) do not run inside: the links land in the mounted project tree and must name the host's paths.

**Consequences.** `dev up` on the host is also the container's install (`dev container up` runs it inside after provisioning dev). The container's Ruby and gems live in the data root, so they survive a rebuild of the writable layer. Two bundles means two installs — necessarily, since native extensions are per platform — but one fetch: bundler's download cache is a store tool cache under the shared data root, so pure-Ruby gems the host fetched are already there for the container (`docs/deps-architecture.md`, transitive-dependency regimes). A `bundle install` on Linux adds `x86_64-linux` to the shared `Gemfile.lock` PLATFORMS — expected, and committed once.

**Rejected.** A host-filter rule ("everything but gems installs on the host") — the plan's original shape; a scope axis names the fact per type instead of encoding it in one integration's exception.

---

## ADR-0003 — A brew lock has bite on both sides

**Status:** Accepted. Milestone 8 of [dev#218](https://github.com/d3mlabs/dev/issues/218).

**Context.** Brew is a moving registry: `brew install cmake` installs whatever `homebrew/core` has today, so `build-deps.lock` recording `cmake 4.4.3` constrained nothing — a host and an image built a month apart from the same lock got different toolchains, silently. Pinning taps was the known fix and the known cost: a `brew tap` of homebrew-core clones its full history, which is what had kept image builds on brew's API.

**Decision.** Two mechanisms, one per side of the container boundary.

- **Hosts verify (B).** After every brew install — and when the formula was already present — `dev deps install` reads `brew list --versions` and fails unless a keg matches the locked version (brew's own `_N` revision suffix aside). The error carries both remediations, because the two causes need different hands: `dev deps update` when brew's formula moved on and the lock is stale; `brew upgrade <formula>` when the machine is behind. Hosts keep brew's API mode — the verification is the contract, not the install path.
- **Images pin (A).** `dev deps update` records per formula the commit its tap was at (`tap_commit`) and `format` — `bottle` when an `x86_64_linux` bottle exists, `source` when the image build would compile it — and names every build-group formula that would build from source, right where the lock is written. `dev deps install --pinned-taps` checks each tap out at its locked commit with a **single-commit fetch** (`git fetch --depth 1 origin <commit>` into brew's taps layout) and installs under `HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1`, so two image builds of one lock install one toolchain. A lock without tap commits, or one pinning a tap at two commits, fails before anything is pinned.
- **Order of landing.** B ships everywhere first. A is opt-in in the image bootstrap (`DEV_PIN_TAPS=1`) until the single-commit fetch has been measured against a real image build; the default image build installs through the API and verifies like a host.

**Consequences.** A stale lock fails loudly instead of drifting. B bites on existing machines whose kegs are behind the lock on the first `dev up` after it ships — the remediation is in the message. Existing locks carry no `tap_commit`/`format` until the next `dev deps update`; only `--pinned-taps` requires them. Casks are not verified (brew reports no stable version for most).

**Rejected.** Pinning taps on hosts too — a host is a workstation with other brew consumers, and a checked-out core tap would fight `brew update`; verification gives the lock its bite there without owning brew. Cloning the taps for pinning — the history cost that kept A off the table; the single-commit fetch is what makes A affordable.

---

## ADR-0004 — A lock describes what is published, not the machine that wrote it

**Status:** Accepted. [dev#232](https://github.com/d3mlabs/dev/issues/232), a consequence of ADR-0003.

**Context.** A brew pin carried one `hash`: the SHA256 of whichever bottle the writing machine would download (`arm64_sonoma` on a Mac, `x86_64_linux` on a Linux box). The same `dev deps update` on two hosts wrote two locks for one version. With the build image content-addressed on `build-deps.lock` (ADR-0001), a Linux re-lock that changed no version still changed every brew hash, so every image tag — a rebuild for nothing — and the hash gated nothing: brew verifies its own bottles. The pre-flight that names source-built formulae had the mirror bug, naming a Mac-only formula (`xcodes`) for an image it never enters.

**Decision.** A repository reports every platform a version publishes — for brew, every bottle tag with its URL and SHA256, read once per formula (brew's own info for tap formulae, the public formula API for `homebrew/core`, whose local info lists only this machine's bottle). The Resolver's projection rule gains a third shape: when the declaration names no platform and no target but the version publishes several, the pin carries a `platforms:` block over all of them. Brew pins carry no top-level `hash`. The projection rule lives in the Resolver, where declarations meet versions — a repository never sees declarations, and which targets a pin describes is a property of both. The pre-flight asks `Installer.select` with the image build's own axes (build group, brew, Linux host, CI env) instead of re-deriving the gate.

**Consequences.** A lock is the same bytes whoever writes it, so a re-lock that changes no version changes no image tag. `format` is derived from the same bottle list as the block, so the two cannot disagree. Existing brew pins keep their `hash` until the next `dev deps update`; readers accept both. The block is a record, not an enforcement input — brew still verifies at install (integrity regimes, `docs/deps-architecture.md`); verifying bottle bytes in dev would be a new regime and is out of scope here. `tap_commit` remains the one fact that varies with the writer's brew state, by design: it is what the pin pins.

**Rejected.** Recording only the image platform's bottle — fixes the churn but keeps the lock partial, and a Mac developer's host install would verify against a Linux hash. Keeping the Mac bottle as `hash` beside the block — a hash that gates nothing is dead weight the content-addressed image still pays for. Putting the "record every platform" rule in `BrewRepository` — it would have to produce a pin shape, which is the Resolver's job; the repository reports facts.
