# Dependency channels: which verb, when to repackage, what the tap admits

The consumer-facing rule for declaring a dependency in `dependencies.rb`: which DSL verb carries it, when a package goes into a channel d3mlabs owns instead of its upstream one, and how the result stays warm on every host dev runs on. The reasoning and the rejected alternatives are [ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel) and [ADR-0011](DECISIONS.md#adr-0011--groups-are-purpose-only-integrations-carry-their-own-manifest-one-lockfile); the design they came from is [plans#50](https://github.com/d3mlabs/plans/issues/50). How the pieces fit inside dev is [deps-architecture.md](deps-architecture.md).

## Vocabulary

- **Channel** — where a dependency's bytes come from: a brew bottle, a GitHub release asset, rubygems, a vendor downloader. Each channel is one DSL verb and one integration.
- **Shape** — what the dependency becomes on disk. An *immutable version-keyed tree* is published once at `<base>/<version>/`, siblings coexist, presence is proof (gh trees, steam depots, the wwise cache; brew kegs are this shape under brew's ownership). A *mutable workdir* is converged in place by a tool toward the lock, one state per directory (a gem home, a venv, a Wine prefix). A *tool cache* is a location dev names and the tool owns. *OS state* is below the floor: provisioning, not a dependency.
- **Scope** — who needs it and where: `group`, `host`, `env`, `platform`.
- **Activation** — putting a dependency on the project's PATH or environment through the project shadowenv. Any shape can be activated; `dev deps path` answers the absolute path for scripts. Activation is a capability every integration has, never a reason to prefer one channel over another.
- **Keg / linking / keg-only / bottle** — brew's words: a keg is one installed version, `Cellar/<formula>/<version>/`; linking symlinks one keg onto PATH; keg-only formulae are never linked; a bottle is a prebuilt binary of a formula.

## Which verb

The first yes decides:

```mermaid
flowchart TD
  start([a new dependency]) --> os{OS state? packages, users, kernel, daemons}
  os -->|yes| inimg{inside the build environment?}
  inimg -->|"yes: a package the build needs"| img["an image block: the image is the pin - floor by digest + apt layer"]
  inimg -->|"no: the floor itself, users, kernel, daemons, a host that is the environment"| prov["provisioning: floor image Dockerfile, dev-box-setup, bring-up block - not declared"]
  os -->|no| lang{imported or linked under a language runtime?}
  lang -->|yes| eco["gem / pip / luarocks"]
  lang -->|no| sup{does a channel dev supports carry it?}
  sup -->|yes| match["the verb for that channel: brew, gh, cmake, steam, xcode, wwise, ..."]
  sup -->|no| adm{does its upstream channel pass the admission test?}
  adm -->|yes| grow["grow the verb: cargo, npm, nix, ..."]
  adm -->|"no, or there is no channel"| rehost{can it be re-hosted?}
  rehost -->|yes| trig{repackage, by what it needs}
  trig -->|"transitive runtime deps to declare"| brewOwn["brew: formula + bottle in d3mlabs/d3mlabs"]
  trig -->|"self-contained tree, large, or licensed"| ghOwn["gh assets: release in a repo we own, private if licensed"]
  trig -->|"the build wants source"| src["cmake github: / gh build:"]
  rehost -->|"no: EULA, login"| vendor["new vendor verb under the relaxed test - the only option left"]
```

**OS state inside the build environment is an `image` block; the rest is provisioning.** A package the build needs on the OS — `winbind`, `dos2unix`, a `libxyz-dev` — goes in the project's `image` block in `dependencies.rb` (dev#277): a floor (`from:` a base image we publish, resolved to its digest), a `platform`, and `apt` lines. dev generates the Dockerfile and **the image is the pin**: the lock records the floor digest, the platform, the apt set and the content digest that is also the registry tag, so a package added is a reviewed lock diff and a new image, never a hand edit to a Dockerfile. `apt` exists only inside that block — there is no `apt` verb, and a tool brew carries is still `brew`. The image carries nothing from the lock; the container's own `dev deps install` installs that inside. Everything else — the floor image itself (its publisher's Dockerfile), users, kernel modules, daemons, and a host that *is* the environment's platform — is still installed by whoever sets the host up: `dev-box-setup`, a workstation's bring-up block. That gap stays, accepted; see ADR-0010 and its 2026-10-25 note.

**A language runtime's own packages take its verb.** A Ruby library is `gem`, a Python one `pip`, a Lua one `luarocks`, whatever else might carry it.

**A supported channel's verb wins over a new one.** The supported channels: `brew`/`cask` (tap-pinned, keg-verified), `gem`, `pip`, `luarocks`, `gh` releases, `cmake` (git and url), `steam`, `ficsit`, and the two vendor channels `xcode` and `wwise`. If the thing you need is in one of them, that verb is the answer, including when a release in our own tap or repo also carries it.

**Growing a verb needs a channel that passes the admission test** — what every `Repository` already has to provide, stated as criteria:

1. an enumerable or addressable universe of versions;
2. immutable published versions — an exact version re-installs the same bytes months later;
3. integrity dev verifies, or the tool enforces from facts in the lock;
4. an install dev can probe per host without root.

Channels that pass and would be added if a project needs them: cargo, npm, nix, conda/pixi. Each costs about what ficsit, luarocks and steam each cost for one project — five classes — once, and nothing per package afterwards. Channels that fail, and why: `apt`/dnf (per-suite versions, archives drop old builds, root, system scope — [dev#284](https://github.com/d3mlabs/dev/issues/284)); snap, winget, floating docker tags (no immutability); docker images as a dependency carrier (an OS, not files — ADR-0007, ADR-0008). `xcode` and `wwise` are admitted under a *relaxed* test — addressable, not enumerable — because their artifacts cannot be re-hosted, so no stricter channel could ever exist for them.

**Sugar verbs are not channels.** `ruby` and `python` express cross-integration coupling (bundler's `ruby` directive, pip's venv) plus activation; underneath they mint a declaration in a real channel.

## When to repackage

An own formula in the tap or an own release in a repo we control is legitimate on exactly three paths, and the formula's or release's description names which one:

1. **No channel exists.** The engine; MSVC under Wine; Ruby (ruby-build is lockable but compiles two to three minutes per host, and the prebuilt rubies that exist are not relocatable).
2. **A channel exists but fails admission.** Wine via apt.
3. **We change the bytes.** Patches, relocation — a reason to own the release even when a supported channel carries the upstream.

Which channel to repackage into follows what the package needs: a **brew formula and bottle** when it has transitive runtime dependencies to declare (`depends_on` installs the closure a bare tree cannot — Ruby's openssl, libyaml, zlib); a **`gh` release** when it is a self-contained tree, large, or licensed (private repo); **source** (`cmake github:` or `gh build:`) when the build wants it.

A *thin lift* — a formula that re-hosts an artifact a supported channel already carries, without changing the bytes — is a stopgap and names its retirement condition. The tap's three (`clang-format@18.1.8`, `powershell@7.4.0`, `axslcc`) were retired 2026-10-29 under [homebrew-d3mlabs#6](https://github.com/d3mlabs/homebrew-d3mlabs/issues/6): clang-format became a `pip` pin in the consumer's venv (the same PyPI wheel, on PATH through the project shadowenv), the other two had no live consumer once `gh` trees activate on PATH.

The economics behind the rule: a channel costs dev once and nothing per package; a repackage costs a formula or release per upstream version, per platform, for as long as we consume it.

## The gh channel: immutable releases

A GitHub release is mutable by default: its tag can be moved, its assets replaced or deleted, the release itself deleted. The gh channel meets the admission test's second criterion — an exact version re-installs the same bytes — on two legs, one per side of the channel.

The consumer's leg is the lock. A `gh` pin records the tag's commit as its `source` and the SHA-256 of every asset it selects, as GitHub reports them; `dev up` verifies each download against the lock and refuses a mismatch. An asset replaced under a tag fails every consumer's install by name; nobody runs the new bytes.

The producer's leg is the repository's **immutable releases** setting (Settings → General → Releases → Immutable releases). With it on, every release cut from then on is frozen: its tag, its assets and its existence can no longer change, and only the notes and the latest designation stay editable. The flag is permanent per release, and GitHub reports it back on the release as `immutable: true`. Releases cut before the setting was enabled stay mutable.

The setting is what keeps a series' **readers** safe. A lock has a digest to check; a workflow's `uses: …@v1` takes whatever the series tag points at and has none, and a lock on `^1` re-locks from the same tag ([Lifecycle](lifecycle.md#gh)). So a gh channel's head may only point at a frozen release: `dev deploy gh` refuses a mutable release before anything moves, naming the setting, and `dev release` warns at the cut when the release it created comes out mutable. Enable the setting on every repository whose releases are a gh channel's heads before its first deploy; a release cut mutable can never be deployed as a head, so cut the next one after enabling.

## Brew, specifically

Brew is the cross-platform binary channel for anything with transitive runtime dependencies: one formula syntax with prebuilt bottles on a Mac and on Linux, tap pinning (ADR-0003), bottle sets (ADR-0004), carry-over (ADR-0005), and the bottle cache in the store. Two things to know as a consumer:

- Two projects or branches may lock two versions of one formula. Brew links one keg onto PATH; dev activates the *locked* keg in the project shadowenv (`.shadowenv.d/515_brew.lisp`, `Cellar/<formula>/<keg>/bin` for every locked formula that has a `bin`), so each project runs its own regardless of which keg brew linked. A `gh` tree with a `bin/` is activated the same way (`515_gh.lisp`).
- `brew upgrade` and `brew cleanup` delete kegs a lock still names. After every install dev adds the locked formulae to `HOMEBREW_NO_CLEANUP_FORMULAE` in your `~/.homebrew/brew.env` (or `$XDG_CONFIG_HOME/homebrew/brew.env`), so your own `brew cleanup` leaves their kegs; the list only grows, since releasing a name needs to know no other project on the machine locks it. dev does not `brew pin`: a pin would refuse the upgrades convergence relies on, and brew warns dependents of a pinned formula may break.
- A keg at another version than the lock is converged, not reported (ADR-0003 note, dev#350, dev#356): dev installs the formula from its tap pinned at the lock's `tap_commit` — a scoped pin, restored after, with brew reading the tap and not its API — up or down, `--force --skip-link` when brew refuses an older keg under the linked one; a lock from before tap commits falls back to `brew update` + `brew upgrade <formula>`. A mismatch that survives either is a stale lock: `dev deps update`.
- `dev deps update`, bare, runs `brew update` and moves every brew pin — and every other channel's — to the newest version its declaration admits, taking today's `tap_commit` with the version (dev#631). `dev deps update <name>` floats the named declarations and what they need, keeps every other pin whose declaration still asks the same thing and whose `source` (`tap@commit` for brew) the lock records, and needs only the registries the named declarations reach: a kept pin whose registry refuses this host (an `image` floor in GHCR without `read:packages`, dev#373) is kept all the same while its `from:` is the floor the pin was resolved from, named in the output as `kept (registry unreachable)` with the refusal — an edited floor the registry did not answer for raises the registry's error instead. The one move a subset re-lock makes on its own is a pin the lock records no `source` for (a lock written before pins carried one; a steam branch tip, always), and the output names it with that reason. The output lists what moved and nothing about what did not — the kept pins are the lock's and are not enumerated — with one exception: a named declaration that re-resolves to the version the lock already has is said `unchanged`, with the rule that confirmed it, so naming it never reads as silence. The last line is `lockfiles updated — now run dev up to install` when the file changed and `deps.lock is current` when it did not.

Kegs live in the brew prefix, outside the data root, so persistence on a host covers two directories: free on a disk or a checkpoint, a second named volume (`dev-linuxbrew`) on a Mac's container.

## Groups, integration tooling, the lockfile

Groups select by consumer role — `dev deps install --group`, `--except` — like bundler groups and npm dev dependencies. Nothing else: `:build` is not special. Where a dependency runs is `host:`.

An integration carries its own `dependencies.rb` in the same DSL a project uses. When a project's manifest uses the integration, dev resolves that manifest into the **project's lock** — ordinary pins in their channel, with provenance (`needed_by: xcode`) — in the scope of the declaration that used it. So a project that pins an Xcode gets `xcodes` in its lock without declaring it; a project that does not, does not. `xcode` and `wwise` ship this way ([dev#290](https://github.com/d3mlabs/dev/issues/290)): their manifests export `brew "xcodes", host: :darwin` and `brew "wwise-cli", tap: "d3mlabs/d3mlabs"`, and the installer orders each needed pin's batch before its user's — see [deps-architecture.md](deps-architecture.md#integration-manifests).

A library's manifest follows the Gemfile/gemspec convention, for every verb: **ungrouped declarations export** to the consumer; **grouped declarations are private**; a library declares **ranges** and the project **locks**; `ruby`, `python` and `env` never propagate. Reading a `gh` library's own manifest at its locked tag — the engine exporting the toolchain it was built with, so the project declares the engine alone — is not yet done ([dev#291](https://github.com/d3mlabs/dev/issues/291)).

A `gh` tree that carries a `dependencies.rb` **and** a `deps.lock` is not a library but a **tool**, and the rule inverts: it exports nothing. It is installed **self-contained** — the Ruby and gems its executables run under are converged into the tree at install from its own lock, or shipped inside the asset when the producer vendored them at release. Nothing from it enters the consumer's lock, gem home or environment; the consumer records one pin and gets the tree's `bin/` on PATH. See [Self-contained trees](dependencies.md#self-contained-trees).

One lockfile, `deps.lock`, every group in it ([dev#293](https://github.com/d3mlabs/dev/issues/293)). `build-deps.lock` is retired with the image-membership role it existed for.

## How warmth survives

Three axes that are easy to discuss as one:

```mermaid
flowchart LR
  subgraph channel [Channel - where bytes come from]
    c1[brew bottle]
    c2[gh release]
    c3[rubygems / pypi / luarocks]
    c4[vendor downloader]
  end
  subgraph host [Build host - where they install]
    h1[Linux workstation]
    h2[Mac + container]
    h3[self-hosted box]
    h4[hosted runner]
  end
  subgraph persist [Persistence - how they survive]
    p1[disk, continuously]
    p2[named volumes]
    p3[checkpoint, discretely]
  end
  channel --> host --> persist
```

The verb is a channel choice. Warmth is shape × the host's persistence mechanism, and has nothing to do with which group a dependency is in or whether it is "build" or "runtime". A workstation and a box persist the data root and brew prefix continuously on a disk; a Mac's container persists them on two named volumes; a hosted runner persists them discretely in the **checkpoint** — a GitHub custom image of the whole boot disk, minted by a `main`-only job after a green run that changed a lock file. A cache action for a workdir ([dev#265](https://github.com/d3mlabs/dev/issues/265)) is an optimization of the gap between the checkpoint and the current lock, built only if the measured gap warrants it. See [Build hosts, cold to warm](runners.md#build-hosts-cold-to-warm).

## What the checkout carries, and gitignores

Two things dev writes live in the project tree rather than the data root, because they are the project's own activation state: `.shadowenv.d/` (the activation lisps, machine-specific absolute paths) and, for a project that declares a `python`, a link to the venv the pin's activation builds. The venv itself is installed state and lives in the store, keyed by project, side and keg — `~/.dev/venv/<name>/<host|container>/<keg version>` — so a hosted job's checkout clean costs no rebuild and two worktrees of one project share it ([dev#399](https://github.com/d3mlabs/dev/issues/399)). A project that declares a `ruby` has a gem home with the same key — `~/.dev/gems/<name>/<host|container>/<keg version>` — reached by the lisp alone, nothing in the tree ([dev#294](https://github.com/d3mlabs/dev/issues/294)). **Activation state is per side**: a lisp names one side's interpreters and a venv is built for one interpreter on one OS/arch, and the build container works on the host's checkout bind-mounted ([dev#648](https://github.com/d3mlabs/dev/issues/648)), so a single file for both sides would be a macOS activation to the host and a Linux one to the container in turn, each `dev up` rewriting what the other side just wrote ([dev#379](https://github.com/d3mlabs/dev/issues/379)). The host writes `.shadowenv.d/` and links `.venv`; the container has `.shadowenv.d-container/` mounted over `.shadowenv.d/` inside (so it writes the same filenames, to its own directory) and links `.venv-container` beside the host's; both sides stay warm. All four are gitignored, with the rest of what dev writes into a checkout: [What dev writes into a checkout](gitignore.md).
