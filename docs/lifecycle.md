# The lifecycle

How `dev` turns a project's `targets:` into builds, artifacts and the
verbs over them. This is the reference the `lib/dev/lifecycle` and
`src/dev/builtins/{build,package}_command.rb` comments point at: the
declarations, the two ports and their env contract, the build grammar,
which verbs exist when, and how a verb decides where it runs. The
decision record is
[ADR-0013](DECISIONS.md#adr-0013-the-lifecycle-model-targets-derived-builds-two-ports-a-stamped-store);
the plan is [dev#192](https://github.com/d3mlabs/dev/issues/192).

## Ontology

Five nouns, each one class, none playing two roles.

| Concept | Class | What it is |
| --- | --- | --- |
| Target | `Lifecycle::Target` | What can be built — the content axis (a client, a server, a gem) — with the axes it varies over (`platforms`, `configs`), a builder spec, a packager spec and an environment. Declared in `dev.yml`. |
| Build | `Lifecycle::Build` | One point of target × platform × config, fully qualified, with one name. Derived, never declared. |
| Build pattern | `Lifecycle::BuildPattern` | A build name with an axis left out; names a set, and has one *default build* (the target's first of each omitted axis). What the verbs' positional parses to. |
| Artifact | `Lifecycle::Artifact` | What `package` makes of one build: the archive beside its `build-id.json`, in the store. A directory without the manifest is not one. |
| Store | `Lifecycle::Store` | `<data root>/artifacts/<project>/<build>/` — one directory per declared build, holding the install, the archive and the manifest. Keyed by the project's `name:`, never the checkout. |

## Declarations

`targets:` is a mapping in declaration order, one entry per target:

```yaml
targets:
  cellbound-3d-editor:
    desc: Editor (dev test, the fast loop)
    platforms: [linux64, macos]
    environment: { linux64: cellbound-3d-linux, macos: host }
    build: ./bin/build-editor
    packager: none
  cellbound-3d:
    desc: Client
    platforms: [win64, linux64]
    configs: [dev, release]
    environment: cellbound-3d-linux
    build: ./bin/build
  rspock:
    desc: The gem
    build: gem build rspock.gemspec --output "$DEV_INSTALL/rspock.gem"
    packager: as-is
```

| Key | Meaning |
| --- | --- |
| `desc` | One line; what `dev help build` shows beside each of the target's builds. |
| `platforms` | A subset of the closed set `win64 \| linux64 \| macos`; the first is the default. Omitted: the target's builds carry no platform segment. |
| `configs` | A subset of `debug \| dev \| release`; the first is the default. Omitted: no config segment. |
| `environment` | Where the target's builds run: an `image` block's name or `host`, one value for every build or one per declared platform. Omitted: the project's default (its one image, the host when none is pinned). Bound against the lock at load; see [Dispatch resolution](#dispatch-resolution). |
| `build` | The builder's script form. Omitted: nothing to compile. |
| `package` / `packager` | The packager: a script, or a built-in by name — `archive` (default; zip, or `{ archive: { format: tar, split: 2GiB } }`), `as-is`, `none`. |

Load-time rules (`Dev::ProjectManifestLoader`): a target name is lower-case
alphanumeric segments joined by single dashes and may not end in a
platform or config id; an id outside the sets is refused with the set
listed; `commands: build:` and `commands: package:` are refused once
targets exist; no command may be named like a build or a pattern. The
rules exist so that a positional `dev build <name>` never has two
readings.

**Declaration order matters once.** Bare `dev build` and `dev package` act
on the first declared target's default build. A project lists its
fast-loop target first.

## Ports and the env contract

Two ports separate dev from the toolchain. The **builder** makes the
*install* — what the toolchain calls done: the compiled, cooked and
staged game; a laid-out file set. The **packager** turns the install into
the *archive* — the one file a release attaches and a channel uploads.
The builder never knows the archive format; the packager never knows the
toolchain.

| Port | Interface | Implementations | Declared as |
| --- | --- | --- | --- |
| Builder | `Lifecycle::Builder#build(build, install)`, `#name`, `#version` | `ScriptBuilder` (`name` = `script`, no version) | `build: <command>` |
| Packager | `Lifecycle::Packager#package(build, install, archive_stem) → PackedArchive` | `Archive` (zip / tar.zst, optionally split), `AsIsPackager`, `ScriptPackager`, `NonePackager` | `packager:` / `package:` |

`Lifecycle::Ports` maps a target's specs to port instances; it is the only
place that knows which class implements which declaration. Integration
builders and packagers (an Unreal builder, a `rubygem` packager) plug in
behind the same two interfaces
([dev#433](https://github.com/d3mlabs/dev/issues/433)); the manifest's
`builder` / `builder_version` fields are the port's `name` / `version`,
so an integration's engine tag lands in `build-id.json` without the verb
changing.

A script form reads its parameters from the environment — never from
flags, which the verb consumes before the seam runs (`Lifecycle::ScriptEnv`):

| Variable | Set | Value |
| --- | --- | --- |
| `DEV_TARGET` | always | the target's name |
| `DEV_PLATFORM` | iff the target declares `platforms` | `win64` / `linux64` / `macos` |
| `DEV_CONFIG` | iff the target declares `configs` | `debug` / `dev` / `release` |
| `DEV_INSTALL` | always | the install directory, created before the builder runs |
| `DEV_ARTIFACT` | `package:` only | the archive path **without its extension**; the script appends what it writes |

An axis the target does not declare is *unset*, not empty, so a script's
`case "$DEV_PLATFORM"` over an undeclared axis fails under `set -u`
instead of matching the empty string. The map from dev's ids to the
toolchain's switches (`dev → Development`, `win64 → Win64`) is the
script's `case`; a declared id it does not handle must fail loudly.

## The build grammar

```
build   := <target> [ "-" <platform> ] [ "-" <config> ]
pattern := <target> [ "-" <platform> ] [ "-" <config> ]     -- any declared axis may be omitted
```

A segment is present exactly when the target declares that axis. Parsing
(`BuildPattern.parse`) takes the longest declared target name that
prefixes the input, then an optional platform id, then an optional config
id, in that order — never a regexp over the whole name, which is why a
target name may not end in a platform or config id.

| Input | Target `cellbound-3d` (`win64 linux64` × `dev release`) | Target `rspock` (no axes) |
| --- | --- | --- |
| `cellbound-3d-win64-release` | the build | — |
| `cellbound-3d-release` | pattern; default build `cellbound-3d-win64-release` | — |
| `cellbound-3d-linux64` | pattern; default build `cellbound-3d-linux64-dev` | — |
| `cellbound-3d` | pattern; default build `cellbound-3d-win64-dev` | — |
| `rspock` | — | the build |
| `cellbound-3d-macos` | `UnsupportedPlatformError` — the target declares no `macos` | — |
| `rspock-dev` | — | `UnsupportedConfigError` — the target declares no configs |
| `cellbound-3d-win64-release-x` | `TrailingSegmentError` | — |
| `opencell` | `UnknownTargetError` | `UnknownTargetError` |

Every verb acts on **one** build. `Dev::BuildSelector` resolves it from
the argv in this order, and refuses anything that names an axis twice:

1. The base: the positional (a name or a pattern), else `--target T`, else
   the first declared target. Two positionals, or a positional beside
   `--target`, are refused.
2. Each axis: `--platform` / `--config` when given (an id the target does
   not declare is refused), else the pattern's own segment, else nothing.
   Both given and different sides — `cellbound-3d-win64 --platform
   linux64` — is `ConflictingSelectionError`, named with both values.
3. The pattern's default build: each omitted declared axis takes the
   target's first.

So `dev build`, `dev build cellbound-3d`, `dev build --target
cellbound-3d`, `dev build cellbound-3d --config dev` and `dev build
cellbound-3d-win64-dev` name the same build in a project that declares
`cellbound-3d` first.

## Presence rules

Verbs are derived, not declared, so each exists exactly when there is
something for it to act on:

| Verb | Present iff | Acts on | Seam |
| --- | --- | --- | --- |
| `build [BUILD]` | `targets:` non-empty | every build | the target's builder (nothing, for a target with no `build:` — the verb says so) |
| `package [BUILD] [--no-build]` | `targets:` non-empty | every build of a target whose packager is not `none` | the builder when stale, then the packager |
| `deploy [CHANNEL] [BUILD]` | a channel exists | — | milestone C ([dev#192](https://github.com/d3mlabs/dev/issues/192)) |
| `release <version>` | a `release:` block | — | milestone D |

A project without targets lists neither `build` nor `package`, and
`dev build` there is "command not found", not "no targets declared".
`dev help build` lists every build with its target's `desc` and its
environment; `dev help package` lists the shippable ones. Both verbs
complete every pattern (`cellbound-3d`, `cellbound-3d-dev`, …) and every
build.

### What `package` does

`package` implies `build`, make-like (K4 in the plan). For the selected
build, in order:

1. Refuse a target declaring `packager: none` by name.
2. Read the tree once: `Lifecycle::GitState` — the short commit sha and
   whether anything is uncommitted. The same reading decides staleness
   and is what the stamp records.
3. Decide whether the builder runs. It is skipped when the target
   declares no `build:`; when `--no-build` is given; or when the store's
   artifact for the build is **current** — `Manifest::Artifact#current?`:
   it was packaged from a *clean* tree at the commit the tree is at now.
   A dirty tree is never current, so an uncommitted change rebuilds
   every time. Otherwise the builder runs into
   `<store>/<build>/install/`.
4. The packager writes `<build>.<ext>` (and parts) beside the install.
5. Last, `build-id.json` is stamped — after the archive, so a failure
   anywhere above leaves no manifest and the directory reads as
   unpackaged:

```json
{
  "stamp": { "schema": 1, "dev_version": "…", "written_at": "20261104T123000Z" },
  "build": "cellbound-3d-win64-release",
  "sha": "0123456789ab", "dirty": false,
  "packaged_at": "20261104T123000Z",
  "builder": "script", "builder_version": null,
  "build_id": "1.4.0+0123456789ab",
  "archive": "cellbound-3d-win64-release.zip", "archive_sha256": "…"
}
```

The build id (`Lifecycle::BuildId`) is `<semver>+<sha>` from a clean tree,
`<semver>+<sha>.dirty.<utc instant>` from a dirty one, `<semver>+unknown.<utc>`
outside git; the semver is the first line of the repo's `VERSION` file
(`Lifecycle::ProjectVersion`), `0.0.0` when there is none. A current
artifact is still re-archived and re-stamped — only the compile is
skipped; the archive is cheap next to the build and the stamp's instant
moves with it.

## Dispatch resolution

Where a verb's seam runs is decided per build, before anything runs, from
the target's `environment:` bound against the lock at load
(`Dev::PlacementBinder#bind_targets` → one `Dev::TargetPlacement` per
target, a `Placement::Host` or `Placement::Image` per declared platform).

**At load**, for every build with a platform, the environment named for
that platform must produce it: an image through the `target_platforms`
its block declares (`ImageDoesNotProduceError` otherwise, with the fix
named); `host` produces the platform this machine is, which cannot be a
load-time refusal because the same `dev.yml` loads on a Mac and on the
Linux box. A build with no platform has nothing to check.

**At the verb**, `Dev::BuildDispatcher` answers for the selected build:

1. Is the target bound at all? When the lock could not be read at load
   (a pin locked by another dev's template, a retired `build-deps.lock`)
   nothing is placed: `dev help build` lists the builds without an
   environment column and the verb refuses (`UnboundTargetError`) until
   `dev deps update` re-locks, since that remediation is served by the
   same tree.
2. Can this host produce the build where it is placed?
   `TargetPlacement#assert_buildable_here!`: a host-placed `linux64`
   build on a Mac is refused (`HostDoesNotProduceError`) and marked
   `(linux64 only)` in the listing; an image-placed build defers to the
   image's declaration, already checked.
3. `Dev::DispatchResolver#resolve(placement)` under the host rule
   ([README: The host rule](../README.md#the-host-rule-native-when-provisioned-from-the-image-inside-it-otherwise)):

| Placement | This machine | Dispatch |
| --- | --- | --- |
| `host` | any | **native** — the seam runs here |
| image *I* | provisioned from *I* (the box, a hosted runner) | **native** |
| image *I* | inside *I*'s container | **native** (a container of another image is `ContainerDriftError`) |
| image *I* | neither (a Mac) | refused, `RemoteDispatchUnavailableError`, with the hosts that would do named — until milestone B's remote dispatch (a snapshot branch run on an enrolled runner, or in the project's container as the degenerate runner) |

The environment column of `dev help build` is the same resolution read
for display: `host`; `cellbound-3d-linux` when this machine runs it
natively; `cellbound-3d-linux (container)` when it would enter the
container.

**The template.** A verb is a `Dev::LifecycleCommand`, run by
`Dev::LifecycleExecutor` as *before → seam → after*: `before` consumes
the argv into the build and the env, resolves the dispatch and hands the
env to it (`Dispatch::Native` returns `Run(env)`; a remote dispatch will
return `Done` once the same verb has run elsewhere); the seam runs over
env only; `after` stamps and reports. Always spawn-and-wait — never an
exec-replace, which would make `after` unreachable
(`.cursor/skills/learnings/command-runner-exec`). A failure in the seam
short-circuits `after`.

## Adding a port implementation

A new builder implements `Lifecycle::Builder` (`build`, `name`,
`version`), a new packager `Lifecycle::Packager` (`package`); both are
wired in `Lifecycle::Ports` from a new `BuilderSpec` / `PackagerSpec`
variant, and nowhere else. The verbs, the selector, the dispatcher and
the store do not change: they see ports and builds, never scripts or
formats.
