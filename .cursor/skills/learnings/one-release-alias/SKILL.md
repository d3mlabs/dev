---
name: one-release-alias
description: MUST be used when renaming or removing anything a project reads from dev — a `DEV_*` key a `builder:`/`packager:`/`run:` script reads, a dev.yml key, a flag, a label set — or when changing a path dev writes in the store.
---

# What a project reads gets a one-release alias; what dev wrote in the store is named for reclaim

No consumer pins dev (ADR-0001), so a rename reaches every adopter on its
next `dev up`. A name a project *reads* — an env key its script reads, a
dev.yml key, a flag — keeps its old spelling for one release as an alias
that resolves to the new thing and prints a line naming the replacement
and the drop; the alias is marked "delete with the next release" and goes
then. A path dev *wrote* in the store (`<build>/install/`, a pre-ADR-0009
tree) is not aliased: the docs name the old path and `rm -rf` it; gc
reclaims only what it placed.

Why: a silent break on upgrade is the one thing the live-infrastructure
model cannot absorb — the operator did not choose the version that broke
them. An alias that never warns never gets removed; a store path aliased
is two places dev reads one thing from.

```ruby
# WRONG: the key is renamed; cellbound-3d's build script fails under set -u
def for_build(build, stage:) = axes(build).merge(STAGE => stage.to_s)

# RIGHT: both keys for one release; the port reports the read, the verb prints it
STAGE_ALIAS = "DEV_INSTALL" # one release's alias of STAGE; delete with the next release
def for_build(build, stage:) = axes(build).merge(STAGE => stage.to_s, STAGE_ALIAS => stage.to_s)
def deprecations = @source.mentions?(ScriptEnv::STAGE_ALIAS) ? [ScriptEnv.stage_alias_deprecation(script: "builder:")] : []
```

The warning comes through the port that owns the contract
(`Builder#deprecations`, `RunnerRoleAliases.warning`), never a class
branch in the verb; detection of a script's read is static over the
declaration and the file it names (`Lifecycle::ScriptSource`) — a child's
env reads are not observable, and a one-release courtesy earns no tracer.

learned-from: dev#678 (`DEV_INSTALL` → `DEV_STAGE`), after dev#657's `--ai-flow` / `ai-orchestrator` aliases and dev#692's `build:`/`package:` aliases — three renames of a read contract in one week, each shipped the same way; ADR-0009's "a tree at the old path is reclaimed by hand" is the store half.
date: 2026-11-24
