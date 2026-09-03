# Dependency architecture

How `dev` turns `dependencies.rb` declarations into installed, pinned,
integrity-checked dependencies. This is the reference the `lib/dev/deps`
code comments point at: the ontology, who owns which decision, how
integrity works per ecosystem, and what to build when adding a new one.

## Ontology

Four ideas, kept strictly apart. Each has one class, and no class plays
two roles.

| Concept | Class | What it is |
| --- | --- | --- |
| Identity | `PackageId` | Which package: `integration` + `name`, plus `source` for source-based deps (a git URL, a `owner/repo` slug). Value object, works as a Hash key. |
| Universe | `Package` → `PackageVersion` | What exists: every version a repository reports, each carrying facts — `platforms`, `digest`, `artifacts` (dev-fetched bytes), `dependencies` (edges), and `metadata` (ecosystem install facts). |
| Requirement | `DependencyDeclaration` | What the user asked for: name, integration, constraint hash, and the install axes (`group`, `platform`, `host`, `env`). |
| Pin | `Dependency` | What was chosen: exact version, integrity hash, metadata. What the lockfile serializes and integrations install. |

Supporting types: `Artifact` (one downloadable file with an optional
published digest), `DependencyEdge` (an outgoing requirement of a
`PackageVersion`, constraint left in the ecosystem's native syntax).

## Layers and their one question

| Layer | Class(es) | The one question it answers | Never does |
| --- | --- | --- | --- |
| Repository | `Repository#find(id, filter:) -> Package` | "What versions of this package exist, and what are their facts?" | Evaluate range constraints; choose among candidates |
| Scheme | `VersionScheme#satisfies?/#sort` | "Does this version satisfy this constraint, and how do versions order?" | Talk to the network; know about declarations |
| Locker | `Locker#lock(declarations)` | "Given this whole declaration set, make the ecosystem tool solve it" | Read the result (that's the repository's find) |
| Resolver | `Resolver#resolve(declarations) -> [Dependency]` | "Which version do we pin, and what transitives follow?" | Fetch bytes; know ecosystem constraint syntax |
| Integration | `Integration#install_all` | "How do these pins become installed software on this machine?" | Resolve versions |

The registry (`Registry::INTEGRATIONS`) is the single wiring table: one
`Entry` per integration symbol declaring its repository, scheme, optional
locker, optional integration, and scope. Consistency tests fail the build
if a `*_repository.rb`, `*_integration.rb`, `*_scheme.rb`, or
`*_locker.rb` class exists without a registry entry.

## The resolve pipeline

`dev update-deps` runs:

1. **Lock** — for each integration with a registered `Locker`, run it over
   that integration's declarations. Today that is bundler only:
   `BundlerLocker` writes the Gemfile and runs `bundle lock`, producing
   `Gemfile.lock`. After this step, tool-solved universes are materialized
   on disk.
2. **Resolve** — the `Resolver`, per declaration:
   - rejects declaration sets where one name carries disagreeing
     constraints (axes — group/platform/host/env — may differ; constraints
     may not);
   - builds the `PackageId` (the constraint's `repo`/`url` becomes the
     id's source) and calls `find`, passing the constraint hash as the
     `filter` — a *locator*, not a predicate: pinned ecosystems need the
     tag/buildid/suffix to know which singleton universe to report;
   - filters the reported versions through the integration's scheme
     (`satisfies?`), treating scheme-unparseable universe versions as
     non-candidates, and drops versions that don't publish every
     explicitly requested platform;
   - picks the highest satisfying version (`sort`), mints the
     `Dependency` from that version's facts (digest → pin hash, metadata
     → pin metadata), and stamps the declaration's `host`/`env` onto the
     pin's metadata;
   - queues the chosen version's `dependencies` edges as synthetic
     declarations that inherit the parent's group/host/env.
3. **Write** — pins go to `deps.lock`.

`dev install-deps` reads the lockfile and hands each integration its pins;
no resolution happens at install time.

```
update-deps ─▶ Locker.lock(decls)          (bundler: Gemfile.lock appears)
            ─▶ Resolver.resolve(decls)
                 ├─▶ Repository.find(id, filter) ─▶ Package{PackageVersion…}
                 ├─▶ VersionScheme.satisfies?/sort   (choice)
                 └─▶ Dependency (pin)            ─▶ deps.lock
install-deps ─▶ Integration.install_all(pins)
```

## Constraint semantics per integration

| Integration | Scheme | Constraint language |
| --- | --- | --- |
| bundler | `GemScheme` | rubygems requirements (`~>`, `>=`, …) — but selection is degenerate: the universe is the lock's singleton choice |
| ficsit | `SemverScheme` | node-style ranges (`^`, `~`, comparators) |
| pip | `Pep440Scheme` | PEP 440 specifiers (`==`, `~=`, wildcards, conjunction) |
| luarocks | `RockScheme` | rockspec-style comparators and `~>` |
| brew, cmake, gh, steam, xcode | `PinnedScheme` | the constraint names an identity (formula suffix, tag/commit, release tag, buildid, exact version); the repository already applied it as the find locator, so every reported version satisfies |

Scheme parse failures split by whose fault they are:
`VersionScheme::InvalidConstraintError` (the user's declaration is wrong —
propagates) vs `VersionScheme::InvalidVersionError` (the universe contains
a version that ignores the ecosystem's conventions — the Resolver skips
that candidate).

## Integrity regimes

Who guarantees the bytes you install are the bytes that were resolved:

- **dev-enforced** — the repository reports a digest fact, the pin carries
  it, and the integration (or `Cache`) verifies downloaded bytes against
  it. ficsit (per-target SHA256 from the API), url (trust-on-first-use:
  download at resolve time, hash, pin), pip (sdist SHA256 from PyPI's
  JSON API), bundler (`Gemfile.lock` CHECKSUMS, verified by
  `bundle install --frozen`).
- **tool-enforced** — the ecosystem tool verifies integrity itself at
  install; dev records what it can for audit but doesn't gate on it.
  brew (bottle SHA256s are brew's own check), gh (release assets carry
  API digests; `gh` downloads), steam (Steam's own depot verification),
  luarocks (rockspec digests checked by luarocks).
- **identity-as-integrity** — git SHAs: pinning the 40-char commit *is*
  the integrity statement; there is no separate digest.

A nil `PackageVersion#digest` means exactly "upstream publishes none" —
never "we didn't bother".

## Adding a new ecosystem

1. **Repository** — subclass `Repository`, implement
   `find(id, filter:) -> Package`. Report facts for every version you can
   enumerate; if the ecosystem's constraint names an identity, use the
   filter as your locator and report the (usually singleton) universe.
   Raise a subclass of `Repository::PackageNotFoundError` when the
   identity doesn't exist. Never pick a version.
2. **Scheme** — if the ecosystem has a native range language, subclass
   `VersionScheme` with its `satisfies?`/`sort`, nesting
   `InvalidConstraintError`/`InvalidVersionError` under the shared bases.
   If constraints are identities, use `PinnedScheme`.
3. **Locker** — only if the ecosystem's own tool must own the whole-set
   solve (transitive co-resolution you can't reproduce): subclass
   `Locker`, make the tool materialize its lock, and have the repository
   `find` read it.
4. **Integration** — subclass `Integration` to install pins.
5. **Registry** — add the `Entry`. The consistency tests will hold you to
   it.
6. **DSL** — add the declaration verb in `dsl.rb`, and its symbol to the
   consistency test's `DECLARATION_INTEGRATIONS`.

## Decision gate: who owns the solve

Two models for whole-set dependency resolution:

- **A. dev-owned** — dev enumerates universes (`find`), evaluates
  constraints (schemes), and picks versions, including joint constraint
  satisfaction across the graph. Full control; enables cross-project
  resolution of another repo's `dependencies.rb`; requires implementing
  real dependency solving per ecosystem.
- **B. tool-owned** — the ecosystem tool solves (bundle lock / pip /
  luarocks at install), and dev records its answer.

**Current stance: per-ecosystem hybrid, leaning A.** The interfaces are
Model A's — `find` + schemes + Resolver choice — and ficsit already
resolves fully dev-owned (universe, ranges, transitives). bundler stays
tool-owned behind `BundlerLocker` because reproducing Bundler's joint
solve is high cost for zero behavioral gain. pip and luarocks currently
pin top-level packages dev-owned and let the tool resolve transitives at
install, same fidelity as before.

Revisit (the gate): if we need cross-ecosystem joint solving, offline
resolution of a foreign project, or reproducible pip/luarocks transitive
pins, the missing piece is per-ecosystem *edge facts* (dependency
metadata in `find`) plus a backtracking solver in the Resolver — the
interfaces already accommodate both (`PackageVersion#dependencies` is the
slot). No interface change is expected; the cost is per-ecosystem edge
enumeration and solver work, so pay it per ecosystem when the need is
real, not up front.
