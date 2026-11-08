# The lifecycle

How `dev` turns a project's `targets:` into builds, artifacts and the
verbs over them, and its `deploy` channels into the places they ship
to. This is the reference the `lib/dev/lifecycle` and
`src/dev/builtins/{build,package,deploy}_command.rb` comments point at:
the declarations, the ports and their env contract, the build grammar,
which verbs exist when, the channel contract, the dependency graph, and
how a verb decides where it runs. The
decision record is
[ADR-0013](DECISIONS.md#adr-0013-the-lifecycle-model-targets-derived-builds-two-ports-a-stamped-store);
the plan is [dev#192](https://github.com/d3mlabs/dev/issues/192).

## Ontology

One class per noun, none playing two roles.

| Concept | Class | What it is |
| --- | --- | --- |
| Target | `Lifecycle::Target` | What can be built — the content axis (a client, a server, a gem) — with the axes it varies over (`platforms`, `configs`), a builder spec, a packager spec and an environment. Declared in `dev.yml`. |
| Build | `Lifecycle::Build` | One point of target × platform × config, fully qualified, with one name. Derived, never declared. |
| Build pattern | `Lifecycle::BuildPattern` | A build name with an axis left out; names a set, and has one *default build* (the target's first of each omitted axis). What the verbs' positional parses to. |
| Artifact | `Lifecycle::Artifact` | What `package` makes of one build: the archive beside its `build-id.json`, in the store. A directory without the manifest is not one. |
| Store | `Lifecycle::Store` | `<data root>/artifacts/<project>/<build>/` — one directory per declared build, holding the install, the archive and the manifest. Keyed by the project's `name:`, never the checkout. Beside the builds, dot-directories dev reserves: `.<channel>/` is a publisher's scratch, `.releases/<tag>/` is where `deploy --release` keeps a release's verified downloads. |
| Channel | `Lifecycle::Channel` | Where shipments go: a name, the builds it **accepts** (patterns in the build grammar) and a publisher spec. Declared as a child of `commands: deploy:`, or contributed by the lock under an integration's name. |
| Shipment | `Lifecycle::Shipment` | One archive as `deploy` hands it to a publisher: the file, the build, the build id, the digest and its **provenance** (`Lifecycle::Provenance`, sealed) — `Store` (the tree the artifact was packaged from) or `Release` (the tag, and the commit `release.json` records). What a deploy is recorded against, and what a script channel is told, differ by provenance; how a publisher ships the bytes does not ([dev#425](https://github.com/d3mlabs/dev/issues/425)). |
| Publisher | `Lifecycle::Publisher` | The channel's protocol — the port `deploy` runs over the selected shipments, on a track, with a scratch, answering with a receipt. `ScriptPublisher` is the `run:` form; an integration publisher is the integration's write side, declared on its registry entry (`publisher:`, [dev#422](https://github.com/d3mlabs/dev/issues/422)). |
| Receipt | `Lifecycle::Receipt` | The publisher's one-line statement of what it did (`run: ./bin/stage`); what the deploy's status carries. |
| Track | `Lifecycle::Track` | Which of a channel's two tracks a deploy ships on — `testing` from the store, `live` from a release ([dev#425](https://github.com/d3mlabs/dev/issues/425)). Decided by the source, never the operator. |
| Deployment record | `Lifecycle::DeploymentRecord` | What dev says about one deploy: the channel, the ref it was made from, the track, the builds with their ids, how it ended and the receipt. One per distinct commit among the shipped artifacts. |
| Deployment ledger | `Lifecycle::GithubDeployments` | The records as GitHub Deployments on the project's repo (environment = channel, ref = commit or tag, payload = track + builds, one status), written through `gh api`; `Lifecycle::Deployment` is a record as the forge holds it (id, when, page). |
| Release tag | `Lifecycle::ReleaseTag` | `v<version>` — the tag `release` cuts, the ref a release's deployments are recorded against, and what `deploy status --release V` reads. |
| Release builds | `Lifecycle::ReleaseBuilds` | What a release contains: the fully-qualified, packageable builds `release.targets` names, or every build of every packageable target under `release: {}`. Owns the list's rules. |
| Release cut | `Lifecycle::ReleaseCut` | The git half of `release`, lifted from what was dev's `bin/release.rb`: a clean tree on a branch, the `VERSION` bump when the project keeps one (with the `Gemfile.lock` line mirroring it when the project is a gem — `ProjectVersion.files`), the tag, the push — read into a `Plan` first, resumable when HEAD is already tagged. |
| Release assets | `Lifecycle::ReleaseAssets` | An artifact's archive under its release name, `<build>-<version>.<ext>` (a split set's parts and a rewritten `MANIFEST`), with the entry `release.json` records for it. |
| Part list | `Lifecycle::PartList` | A split archive's `MANIFEST`: `<sha256>  <part>` per line, the shape `sha256sum -c` reads. Written by the archive, renamed by the release assets, read back by the release download to know which parts to fetch and what each must hash to. |
| Release archive | `Lifecycle::GithubReleases` | The release on the forge: one GitHub release per tag, created once, its assets uploaded with `--clobber` so a retry replaces what a failed run half-attached, downloaded back by name. Through `gh`, like the ledger. |
| Release archives | `Lifecycle::ReleaseArchives` | A cut release read back for `deploy --release` ([dev#425](https://github.com/d3mlabs/dev/issues/425)): `release.json` downloaded fresh, the selected archives downloaded into `.releases/<tag>/` and **verified** against the digests it records (a split set's parts against its `MANIFEST`); a file already there that verifies is not fetched again, one that does not is removed and refused. |
| Snapshot | `Lifecycle::Snapshot` | The working tree as a remote build host can reach it: a commit made through a temporary index, on its `Lifecycle::SnapshotBranch` (`dev/build/<runner>/<id>`) at `origin`, for as long as a remote dispatch needs it. See [The sync step](#the-sync-step). |
| Verb invocation | `Lifecycle::VerbInvocation` | A verb as a remote host is told to run it: the words after `dev` (the build fully qualified, the dispatch flags consumed) and what to bring back (`Lifecycle::ArtifactFetch`: the workflow artifact's name — the build's — and the store directory it lands in). What every verb's `before` hands its dispatch beside the env. |
| Workflow run | `Lifecycle::WorkflowRun` | One run of the generic workflow as the forge lists it: id, page, GitHub's `status` and `conclusion`. `Lifecycle::WorkflowRuns` is its client over `gh` (dispatch, locate, watch, view, download); `Lifecycle::LifecycleWorkflow` is the contract of the workflow itself — the file name, its inputs, dev's shipped copy. See [The remote dispatch](#the-remote-dispatch). |
| Step outputs | `Lifecycle::StepOutputs` | What `package` tells the Actions job it runs in (`GITHUB_OUTPUT`): the artifact's name and files, so the workflow uploads exactly what `--fetch` downloads. Inert outside a job. |

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

### Channels

With targets declared, `commands: deploy:` is not a command: each child
is a **channel**, parsed by `Dev::ChannelParser` against the targets and
lifted out of the command tree into `ProjectManifest#channels`.

```yaml
commands:
  deploy:
    commands:
      staging:
        desc: rsync to the gamebox
        targets: [cellbound-3d-server]
        run: ./bin/stage
        environment: host
      steam:                              # no run: — the lock's steam dependency publishes
        desc: Steam depots
        targets: [cellbound-3d-steamworks-win64-release, cellbound-3d-server-linux64-release]
        steam:                            # the publisher's options, under the channel's name
          app: 480
          depots:
            cellbound-3d-steamworks-win64: 481
            cellbound-3d-server-linux64: 482
      ficsit:                             # no run: — the lock's SML dependency publishes
        targets: [snappy-steam]
```

| Key | Meaning |
| --- | --- |
| `desc` | One line; what `dev help deploy` shows beside the channel. |
| `targets` | The **accept set**: a non-empty list of builds or patterns in the build grammar, parsed at load (`BuildPattern.parse`), so a name no target spells is refused before anything runs. |
| `run` | The protocol's script form: a shell command run at the repo root once per archive, with the env contract below. Omitted, the protocol is the publisher the lock contributes under the channel's name (`PublisherSpec::Integration`). |
| `environment` | Where the script runs — a command's key, values and binding (`Dev::PlacementBinder#bind_channels`). Needs `run:`; an integration publisher is dev's own code and is placed on the host. |
| `<channel>` | The lock publisher's **options** ([dev#426](https://github.com/d3mlabs/dev/issues/426)): a mapping under the channel's own name (`steam:` on `steam`, `egs:` on `egs`), carried verbatim as `Lifecycle::Channel#options` and read by the publisher at the start of a deploy in its own vocabulary — see [the channel contract](#the-channel-contract) for each. Refused beside `run:` (`ChannelOptionsError`): the script replaced the publisher it would configure. Refused when not a mapping. |

Load-time rules: `deploy` itself may carry no `run:` (`DeployBodyError`)
and must have a child (`NoChannelsError`); a child must be a mapping
(`InvalidChannelError`) with `targets:` (`ChannelAcceptsError`), may not
carry `environment:` without `run:` (`ChannelEnvironmentError`), may not
carry its publisher's options beside `run:` (`ChannelOptionsError`), may not
have `commands:` of its own (`ChannelChildrenError`) and may not be named
`help` or `status` (`ReservedChannelNameError` — both are `deploy`'s own
children). A `deploy` child carrying `targets:` in a project without
targets is refused (`ChannelWithoutTargetsError`): there is no build for
it to accept. Without targets, `deploy` stays a plain project command,
children included.

**The lock contributes channels** ([dev#422](https://github.com/d3mlabs/dev/issues/422)).
An integration with a write side declares it on its registry entry as a
`publisher:` port (`Deps::Registry::Entry`, beside `integration:` — the
install is the read side, the publisher the write side, both the same
dependency, [ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel)),
and every project whose lock reaches that entry — directly or through an
`install_alias`, as `ruby:` pins reach brew — gets a `deploy` channel of
the entry's name (`Dev::ProjectPublishers`) — or of the **destination's**
name where the two differ (`Entry#channel`): gems pinned through the
`bundler` type ship to `rubygems`, an `image` pin reaches `ghcr`
([Built-in publishers](#built-in-publishers)). Nothing in `dev.yml` names a
publisher. The declared and the contributed sets merge by name in
`Dev::ChannelBinder`, at the composition root, before the command tree
exists — the "third merge case" of `CommandRepository#merge`, applied to
channels since `deploy`'s children never land on the builtin's slot:

| Declared | Contributed | Result |
| --- | --- | --- |
| with `run:` | any | the script **replaces** the publisher; dev's stage still selects, checks and records |
| without `run:` | a publisher of that name | the declaration **configures** it: `targets:` is the accept set, `desc` is the row, the protocol is the integration's |
| without `run:` | none | binds with a **fault** ([dev#509](https://github.com/d3mlabs/dev/issues/509)) that says why — *this dev ships no `x` publisher* (a release ahead of the installed dev: `dev up` once one ships it) or *deps.lock pins no `x`* (depend on it in `dependencies.rb`, `dev deps update`) — or declare `run:`. It lists in `dev help deploy` with the cause on its Protocol line; `deploy <channel>` refuses with the full message (`DeployCommand::UnboundChannelError`). Every other verb runs: a manifest ahead of the installed dev must not take `dev deps install` down with it |
| — | a publisher | the channel appears as the lock's: every packageable build accepted, a stock `desc`; a project with nothing packageable gets no row |

### The release

With targets declared, `commands: release:` is not a command either
([dev#424](https://github.com/d3mlabs/dev/issues/424)): it says what a
release **contains**, parsed by `Dev::ReleaseParser` against the targets
into `Lifecycle::ReleaseBuilds` and lifted out of the command tree into
`ProjectManifest#release`. The verb's body is dev's own (below).

```yaml
commands:
  release:
    desc: Cut a release
    targets: [cellbound-3d-release, cellbound-3d-server-linux64-release, rspock]
```

```yaml
commands:
  release: {}                           # every build of every packageable target
```

| Key | Meaning |
| --- | --- |
| `desc` | One line, optional; the verb's row is dev's. |
| `targets` | The builds a release contains: a non-empty list in the build grammar, **the config named** — `cellbound-3d-release` spells both platforms at release config; `cellbound-3d-win64`, spanning `dev` and `release`, is refused at load (`ReleaseBuilds::ConfigNotNamedError`) with the names to pick. A target of `packager: none` has nothing to attach (`NotPackageableError`); a build named twice is refused (`DuplicateBuildError`); a name no target spells is the grammar's error. |

The empty form — `release: {}`, or `release:` with nothing under it — is
every build of every packageable target, allowed when each such target
declares at most one config; a target with several is refused
(`ConfigNotNamedError`) naming the fully-qualified alternatives, since
the release would otherwise attach both configs of one target. A project
with nothing packageable has nothing to release (`NothingToReleaseError`).

Load-time rules: `release` may carry no `run:` (`ReleaseBodyError` — the
body is dev's cut), no `commands:` (`ReleaseChildrenError` — the verb
takes a version) and no key but `targets` and `desc`
(`UnknownReleaseKeyError` — where each build runs is its target's
`environment:`); `release:` must be a mapping or empty
(`InvalidReleaseError`); `targets:` a non-empty list of strings
(`ReleaseTargetsError`). A `release` carrying `targets:` in a project
without targets is refused (`ReleaseWithoutTargetsError`); without
targets, `release` stays a plain project command — what dev's own
`bin/release.rb` was until [dev#429](https://github.com/d3mlabs/dev/issues/429)
made dev a lifecycle project of its own (two targets, `dev-core` and
`dev`; `release: {}`; a `deploy brew` channel — see [The brew
publisher](#the-brew-publisher)).

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
| Publisher | `Lifecycle::Publisher#publish(shipments, channel:, track:, scratch:) → Receipt` | `ScriptPublisher`; the lock's integration publishers | a channel's `run: <command>`; a registry entry's `publisher:` |

A third port, the **publisher**, is the channel's: it takes the
shipments `deploy` selected and ships them, never choosing on its own and
never rewriting an archive (see [The channel contract](#the-channel-contract)).

`Lifecycle::Ports` maps a target's specs — and a channel's — to port
instances; it is the only place that knows which class implements which
declaration, and it holds the publishers the lock contributed, by channel
name, so a `PublisherSpec::Integration` resolves to its instance. Integration
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
| `DEV_INSTALL` | `build:` and `package:` | the install directory, created before the builder runs |
| `DEV_ARTIFACT` | `package:` | the archive path **without its extension**; the script appends what it writes |
| `DEV_ARTIFACT` | a channel's `run:` | the archive **file** — the path with its extension, as the store or the release download holds it |
| `DEV_CHANNEL` | a channel's `run:` | the channel's name |
| `DEV_TRACK` | a channel's `run:` | `testing` / `live` — the track this deploy ships on |
| `DEV_SCRATCH` | a channel's `run:` | the channel's scratch directory, created before the first run and kept between deploys |
| `DEV_BUILD` | a channel's `run:` | the build's full name (`cellbound-3d-win64-release`) |
| `DEV_BUILD_ID` | a channel's `run:` | the build id the archive was packaged under (`1.4.0+0123456789ab`) |
| `DEV_ARCHIVE_SHA256` | a channel's `run:` | the archive's digest, as `build-id.json` or `release.json` records it |
| `DEV_SHA` | a channel's `run:` | the commit: the one the artifact was packaged at (`unknown` outside git), or the release's tag commit, short |
| `DEV_DIRTY` | a channel's `run:`, from the store | `true` / `false` — whether that tree had uncommitted changes |
| `DEV_PACKAGED_AT` | a channel's `run:`, from the store | the UTC instant (`20261104T123000Z`) |
| `DEV_RELEASE_VERSION` | a channel's `run:`, under `--release` | the version as given (`1.2.0`); the tag is `v$DEV_RELEASE_VERSION` |

An axis the target does not declare is *unset*, not empty, so a script's
`case "$DEV_PLATFORM"` over an undeclared axis fails under `set -u`
instead of matching the empty string. The same rule tells a channel's
script where its archive came from: `DEV_RELEASE_VERSION` is set only for
a release's archive, `DEV_DIRTY` and `DEV_PACKAGED_AT` only for the
store's — a release is cut from a clean tree at its tag, so it has
neither to report. The map from dev's ids to the
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
| `deploy <channel> [BUILD] [--config C] [--release V] [--allow-stale] [--force] [--dry-run]` | a channel exists — declared under `commands: deploy:` or contributed by the lock | the channel's accepted archives: from the store, or from release `V`'s assets | the channel's publisher, over the selection, on the testing track from the store and the live track from a release; `after` records the deploy on the forge |
| `deploy --release V [--dry-run]` | a channel exists | every channel, in declaration order | `deploy <channel> --release V` per channel, through the same template; stops at the first that refuses |
| `deploy status [--release V]` | a channel exists — declared or contributed | every channel's latest recorded deploy; the release's tag only under `--release` | — (reads the ledger; a builtin child of `deploy`, which reserves the name `status`) |
| `release <version>` | `commands: release:` declared (`targets:` or the empty form) and at least one packageable target | the release builds, each packaged at the tag | the cut and the push, then `package` per release build, each dispatched by its own environment; `after` creates the GitHub release and attaches the archives |

A project without targets lists neither `build` nor `package`, and
`dev build` there is "command not found", not "no targets declared";
one without a channel lists no `deploy`; one without a `release:` block
lists no `release`, and `dev help release` lists what a release contains
under `Release builds:`. `dev help build` lists every
build with its target's `desc` and its environment; `dev help package`
lists the shippable ones. Both verbs complete every pattern
(`cellbound-3d`, `cellbound-3d-dev`, …) and every build. `deploy` is a
verb heading children (`Dev::Builtins::DeployAllCommand`): the channels
(`Dev::Builtins::DeployCommand`, one per channel) plus `status`
(`Dev::Builtins::DeployStatusCommand`, which reads the ledger). `dev help
deploy` lists each with its environment column, its accept set expanded
to builds (`Accepts: …`) and its protocol's source (`Protocol: run:
./bin/stage`, `Protocol: publisher: steam`), and a channel completes its
accept patterns and the builds they span. The node itself runs only the
release fan-out (`dev deploy --release V`, below); bare `dev deploy` is
refused with the verb's shape — the store ships one channel at a time —
and a word naming no channel is refused by name (`NoChannelError`,
`UnknownChannelError`). No channel may be named `help`, `status` or
`releases` (`ChannelParser::RESERVED_NAMES`).

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
(`Lifecycle::ProjectVersion`) as it is when the stamp is written — so an
artifact packaged after `release`'s bump commit carries the released
version — `0.0.0` when there is none. A current
artifact is still re-archived and re-stamped — only the compile is
skipped; the archive is cheap next to the build and the stamp's instant
moves with it.

### What `deploy` does

`deploy` never builds (K4): it ships what `package` left in the store —
or, under `--release <version>`, what `release` attached to the GitHub
release — and refuses, naming the fix, when that is not enough. For
`dev deploy <channel> [BUILD]`, `Dev::DeploySelector` decides what
ships, in order:

1. The candidates: the channel's accept set spelled out **per platform**
   (`Channel#artifact_patterns` — `cellbound-3d` over two platforms is
   two entries, each with its config open), or, with a `BUILD`
   positional, that name or pattern split the same way and narrowed to
   the builds the channel accepts. A positional spanning no accepted
   build is `OutsideAcceptSetError` with the accept set named; `--force`
   keeps every build the positional spans. `--force` without a positional
   is refused: it only widens what was named. One artifact ships per
   entry.
2. The config, per entry: `--config C` keeps the builds of that config
   (`NoAcceptedConfigError` when none is accepted); otherwise every
   accepted config is a candidate.
3. The store: among the candidates, the artifacts that exist. None is
   `MissingArtifactError` ("`dev package <build>` first; deploy never
   builds"); several is `AmbiguousArtifactError`, both listed, with
   `--config` as the fix — the "unique match or explicit" rule of
   cellbound-3d's staging deploy.
4. Staleness: an artifact whose `build-id.json` is not from a clean tree
   at this commit (`Manifest::Artifact#current?`, the same rule
   `package` reads) is `StaleArtifactError` unless `--allow-stale`, which
   ships it and marks it in the report.

With `--release <version>` ([dev#425](https://github.com/d3mlabs/dev/issues/425))
steps 1 and 2 are the same and the **source** changes: the release on
the forge, read through `Lifecycle::ReleaseArchives`. Its `release.json`
is downloaded first — always, the release being the truth about itself
(`NoReleaseError` names the `dev release` that would cut it; a manifest
naming another tag is `TagMismatchError`) — and step 3 reads it instead
of the store: among the candidates, the builds the release carries an
archive of. None is `NotInReleaseError` — a release ships what `release:`
cut into it, deploy adds nothing, and the store never substitutes;
several is `AmbiguousReleaseArchiveError` with `--config` as the fix.
The selected archives are then downloaded under their asset names into
the store's `.releases/<tag>/` (`Store#release_dir`) and each
**verified** against the digest `release.json` records — a split set's
`MANIFEST` first, then every part it lists against the `MANIFEST`
(`Lifecycle::PartList`); a file already there that verifies is not
fetched again, so a release fanned out over several channels crosses
the wire once; one that does not verify is deleted and refused
(`ChecksumMismatchError`), and nothing ships. There is no step 4: a tag
is immutable, so `--allow-stale` beside `--release` is refused
(`AllowStaleWithReleaseError`). Each selected archive becomes a
`Lifecycle::Shipment` with the release as its provenance — the tag, and
the commit `release.json` records — where a store artifact's carries the
tree it was packaged from.

Then the verb's template: `before` resolves where the protocol runs (the
channel's `environment:` under the host rule), reads the tree once,
consumes the argv into the selection — which carries the track:
**testing** from the store, **live** from a release — takes the
channel's publisher from `Lifecycle::Ports` and the channel's scratch
(`Store#scratch`); the
seam is the publisher, over the whole selection in one call —
`ScriptPublisher` creates the scratch and runs the `run:` line at the
repo root once per archive, with `Lifecycle::ScriptEnv.for_deploy`'s
env (`DEV_RELEASE_VERSION` set for a release's archive, `DEV_DIRTY` and
`DEV_PACKAGED_AT` for the store's), and stops at the first nonzero exit
(`DeployScriptFailedError`, the archive and code named; the ones before
it shipped); an integration publisher ships its own way — skipped under
`--dry-run`; `after` prints one line per shipment (`deployed <build>
(<build id>) → <channel> (<track>): <archive>`, `would deploy …` under
`--dry-run`, `— stale, shipped under --allow-stale` when it was), then
records the deploy ([The deploy receipt](#the-deploy-receipt)).

Under a remote dispatch (`--runner`, or the channel's `environment:`
placing the protocol elsewhere) the words carried to the host include
`--release V`: the host downloads the release into *its* store and
verifies it there, as it selects from its own store without one (K10 —
deploy never fetches an artifact across the dispatch).

`dev deploy --release <version>` with **no channel** is the fan-out
(`Dev::Builtins::DeployAllCommand`): every channel in declaration order,
each run as `dev deploy <channel> --release <version>` through the same
template — the invocation printed as a header before each, the summary
`v1.2.0 shipped to 2 channels: steam, rubygems` after the last. The
first channel that refuses (a release carrying nothing it accepts, a
protocol that fails) ends the fan-out there, the earlier channels
deployed and recorded; the error names the channel, and the fix is to
name the channels. `--dry-run` fans out the rehearsal. `--config`,
`--allow-stale` and `--force` qualify one channel's selection and are
not accepted by the fan-out; `--runner` is, and reaches each channel.

### The deploy receipt

Every deploy that ships is recorded (K5/K6,
[dev#423](https://github.com/d3mlabs/dev/issues/423)) as a **GitHub
Deployment** on the project's repo — `gh repo view`'s, resolved once per
run and only when a record is written or read, so `dev help` never asks
the forge. The record (`Lifecycle::DeploymentRecord`) maps onto GitHub's
object as:

| GitHub Deployment | dev |
| --- | --- |
| `environment` | the channel's name |
| `ref` | the shipment's provenance: the commit the artifact was packaged from (`build-id.json`'s sha) for the store, the release's tag (`v1.2.0`) under `--release`. One deployment per distinct ref among the shipments, so `--allow-stale` shipping two commits records two — the ledger is honest about provenance — and a release's deploy is always one, against the tag `deploy status --release` reads. An artifact packaged outside git has no ref and is not recordable (`UnknownRefError`). |
| `payload` | `{ schema: 1, track: testing \| live, builds: [{ name, build_id }] }` — dev's, and what `status` reads back |
| `description` | `dev deploy <channel>: <build names>` |
| `production_environment` | `true` for the live track |
| `auto_merge`, `required_contexts` | `false`, `[]` — the ledger describes a deploy, it never gates one |
| one status | `success` with the publisher's **receipt** as its description (cut at GitHub's 140 characters), or `failure` with the protocol's error when the seam refused |

The receipt crosses from the seam to `after` on the verb's env
(`DeployEnv#receipt`, as `PackageEnv#packed` does for the archive). The
**track** is the verb's decision from where the shipments came —
`DeploySelector::Selection#track`, `testing` for the store, `live` for a
release — never the publisher's. Recording is best-effort around the protocol and never
masks it: a deploy that shipped but could not be recorded
(`NotRecordedError`) fails *after* the `deployed …` lines, so the upload
is never mistaken for undone; a failed deploy whose failure record the
forge refuses says so on stderr beside the protocol's own error.
`--dry-run` records nothing. `after` names what it wrote: `recorded as
GitHub Deployment #41 (testing track) →
https://github.com/<owner>/<repo>/deployments/staging`. The write goes
through `gh api`, so the token `gh` holds needs `deployments: write`
(the `repo` scope has it; a fine-grained token names it).

### What `deploy status` does

`dev deploy status [--release V]` (`Dev::Builtins::DeployStatusCommand`)
reads the ledger back, per channel in declaration order: the latest
deployment — `GithubDeployments#latest`, the first of
`?environment=<channel>&per_page=1`, its first status — as one headline
and then the builds it carried:

```
rubygems  – nothing deployed
staging   ✓ testing from 3f2a1c9d8e7b at 2026-11-05 17:02 UTC — run: ./bin/stage
          cellbound-3d-server-linux64-release (1.4.0+3f2a1c9d8e7b)
steam     ✗ testing from 9b8c7d6e5f4a at 2026-11-04 09:10 UTC — failed: deploy script `./bin/steam` for cellbound-3d-win64-release → steam exited 2
```

A deployment the forge holds without a status reads `… pending …`.
`--release 1.2.0` asks the same question of the release's tag only
(`&ref=v1.2.0`), so the output is the checklist of which channels carry
that release and which still read `– v1.2.0 not deployed`. The command
takes no positional and lives under `deploy` because status is the
**channel's**, not the release's: the release records what the cut
made, the ledger what each channel received — which is also why
`ChannelParser` refuses a channel named `status`. Every failure of the
forge is a typed `GithubDeployments::Error` (`RepoUnresolvedError`,
`ApiError`, `MalformedDeploymentError`) and surfaces as the command's.

### What `release` does

`dev release <version>` (`Dev::Builtins::ReleaseCommand`) is **cut and
stop** (K4): the tag and the archives on the forge, nothing deployed —
distribution is `dev deploy <channel> --release <version>` per channel
([dev#425](https://github.com/d3mlabs/dev/issues/425)), a week later
from the same bytes if need be. The cut is lifted from what was dev's
own `bin/release.rb`; the verb orchestrates from wherever it was invoked
(K10), its own dispatch native, and runs `package` **as itself** per
release build so each dispatches by its target's `environment:`. In
order:

1. **`before` — the plan.** The version becomes the tag (`ReleaseTag`,
   `v1.2.0`). `ReleaseCut#plan` reads the checkout and moves nothing: the
   tree must be clean (`DirtyTreeError`, with `git status`) and HEAD on
   a branch (`DetachedHeadError`); a tag of that name elsewhere than HEAD
   is a version already cut (`TagElsewhereError`); a tag already **on**
   HEAD means a previous run's cut landed and this one **resumes**. The
   bump: when the project keeps a `VERSION` file whose version is not
   the release's, `from → to`; none otherwise. The notes: the one-line
   log since the previous tag, `Release v1.2.0.` for a first release.
2. **The seam — cut, push, package.** The plan is announced (`cutting
   v1.2.0 on main: bump VERSION 1.1.0 → 1.2.0, tag, push`, or `resuming
   v1.2.0: HEAD is already tagged — …`). `cut!` writes `VERSION`,
   commits `Bump version to 1.2.0` and tags HEAD — a no-op when
   resuming; `push!` pushes the branch and the tag to `origin`
   (idempotent). Then, for each release build in declaration order,
   `package` runs through the `LifecycleExecutor` with the build as its
   positional — the builder when stale, the packager, the stamp — and
   the artifact is read back from the store, which must be **current at
   the tag's commit** (`ArtifactNotAtTagError` otherwise: packaged
   elsewhere, or the tree moved). The bump commit makes every earlier
   artifact stale by construction, which is why the cut comes first and
   why the build ids read `1.2.0+<tag sha>`. A failure here leaves the
   tag pushed and the release uncreated; the retry resumes.
3. **`after` — the forge.** `ReleaseAssets` gathers each archive under
   its release name, `<build>-<version>.<ext>` (`cellbound-3d-win64-release-1.2.0.zip`;
   a split set's parts as `<build>-<version>.tar.zst.00`, … with a
   rewritten `<build>-<version>.MANIFEST`), as links in a temporary
   directory, and `release.json` (`Manifest::Release`) is written beside
   them. `GithubReleases` finds the tag's release or creates it
   (`gh release create v1.2.0 --verify-tag`, title the tag, notes from
   the plan) and uploads every asset with `--clobber`, so a run that died
   mid-upload is healed by the next. The report:

```
released v1.2.0 (0123456789ab) → https://github.com/d3mlabs/cellbound-3d/releases/tag/v1.2.0
  cellbound-3d-win64-release-1.2.0.zip (1.2.0+0123456789ab)
  cellbound-3d-server-linux64-release-1.2.0.zip (1.2.0+0123456789ab)
  release.json
nothing deployed — `dev deploy <channel> --release 1.2.0` ships it
```

`release.json` is what `deploy --release` reads to pick a channel's
archives out of the release and verify them:

```json
{
  "stamp": { "schema": 1, "dev_version": "…", "written_at": "20261106T123000Z" },
  "tag": "v1.2.0", "sha": "0123456789abcdef…",
  "archives": [
    { "build": "cellbound-3d-win64-release", "name": "cellbound-3d-win64-release-1.2.0.zip",
      "sha256": "…", "build_id": "1.2.0+0123456789ab" }
  ]
}
```

A `release` without a version, or with two, is refused before the plan
(`VersionArgumentError`); a word that cannot name a tag is the tag's
refusal. Every failure of the forge is a typed `GithubReleases::Error`
(`ApiError`, `MalformedReleaseError`), a refused push is git's own, and
each surfaces as the command's.

## The channel contract

A channel is a destination; its **publisher** is the protocol that
reaches it. Two kinds share one interface,
`Lifecycle::Publisher#publish(shipments, channel:, track:, scratch:)`:

| Publisher | Declared as | Knows |
| --- | --- | --- |
| `ScriptPublisher` | the channel's `run:` | nothing but its env: the script owns the endpoint, the credentials, the tool |
| an integration publisher | the integration's registry entry (`publisher:`), reached by the project's lock; the channel is the entry's name, or its `channel:` when the destination is called otherwise | the endpoint, the app id and depots, the release asset layout — from the integration's declaration, not from `dev.yml` |

Both obey two constraints, which is what makes the verb the same over
either:

- **A publisher reads the archive and never rewrites it.** The file is
  what the shipment's `archive_sha256` says — `build-id.json`'s for the
  store, `release.json`'s for a release — before and after a deploy; a
  channel that needs another layout copies into its **scratch** —
  `<data root>/artifacts/<project>/.<channel>/`, a dot-directory beside
  the builds so it never reads as one, created before the publisher runs
  and kept between deploys (an unpacked tree Steam's content builder can
  diff against, SMR's staged upload).
- **A publisher ships what the verb selected, never selecting on its
  own.** The accept set, the config choice, the source, the staleness
  and force rules are `DeploySelector`'s and identical for every
  protocol; a publisher gets the shipments, in order, one call per
  deploy. A shipment's **provenance** (`Lifecycle::Provenance::Store` or
  `::Release`, sealed) is there for the publisher that must know — a
  formula points at a release asset by tag, never at a file in a store —
  not for one to decide anything the verb already has.

Credentials are the publisher's concern — the project's `dev cred` store
or the script's environment — never `dev.yml`'s.

**Tracks.** A channel has two, `Lifecycle::Track`, and the publisher
maps them onto its own (Steam's beta branch and default branch, SMR's
`beta` and `release` stabilities, a staging rsync's one); which one a
deploy ships on is the **source's** decision, never the operator's: an
artifact from the store goes to `testing`, an archive of a release
(`deploy --release`, [dev#425](https://github.com/d3mlabs/dev/issues/425))
to `live`. That is the whole statement of "irreversible channel": a
deploy from the store never touches live, and nothing in `dev.yml` can
change it. The track is the verb's to pass, never the publisher's to
pick.

**Receipts.** A publisher **returns a receipt** (`Lifecycle::Receipt`):
one line stating what it did, which the verb writes into the deploy's
GitHub Deployment status ([The deploy receipt](#the-deploy-receipt));
`ScriptPublisher`'s is `run: <command>`.

**Where a publisher comes from.** The `publisher:` on a
`Deps::Registry::Entry` is the integration's write side, the way
`integration:` is its install: one dependency, both directions
([ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel)). The
Registry builds one instance per publishing entry the lock reaches
(`Registry.publishers`), with the kwargs the entry's `publisher_needs`
asks for; `Dev::ProjectPublishers` reads the lock once and asks; the
Runner hands the table to `ChannelBinder` (the merge) and to `Ports` (the
lookup). A built-in publisher is its integration's **repository class**
when the write side shares the read side's API and credential story —
`FicsitRepository` resolves mods from ficsit.app and publishes to it — and
its own class otherwise. The built-in write sides are below — the
registries' ([dev#428](https://github.com/d3mlabs/dev/issues/428)),
`steam`/`egs` ([dev#426](https://github.com/d3mlabs/dev/issues/426)) and
`ficsit` ([dev#427](https://github.com/d3mlabs/dev/issues/427)) and `brew`
([dev#429](https://github.com/d3mlabs/dev/issues/429)); and
an external integration's publisher arrives through
[dev#300](https://github.com/d3mlabs/dev/issues/300)'s integration gems.

### Built-in publishers

Each is the write side of a dependency type dev already resolves from the
same store, so a project gets the channel by depending on the store
([ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel)), and
each maps the two tracks onto what its destination has
([dev#428](https://github.com/d3mlabs/dev/issues/428)):

| Channel | Reached by | Publisher | Archive | `testing` | `live` | Credentials | Receipt |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `rubygems` | a `gem` declaration (the `bundler` type) | `Deps::RubygemsPublisher` — `gem push --host https://rubygems.org <archive>`, once per gem, at the repo root | a `.gem` (the target's `packager: as-is` over `gem build`; [dev#434](https://github.com/d3mlabs/dev/issues/434)'s `rubygem` packager) — anything else is refused before the first push | **refused** (`TestingTrackUnsupportedError`): rubygems.org has no track that is not live — a pushed version can never be reused, so a working artifact has nowhere to go; the message names `dev deploy rubygems --release <v>` | pushed | `dev cred` under `rubygems api_key` (`GEM_HOST_API_KEY` in the environment overrides it, the variable `gem` reads), handed to `gem push` through its env, never on argv | `pushed to https://rubygems.org: <file>, …` |
| `ghcr` | an `image` block | `Deps::GhcrPublisher` — `docker load` of every archive first (a tarball that is not an image, carries no tag, or is tagged under another registry refuses the deploy with nothing pushed), then `docker tag` + `docker push` per image inside one `RegistryLogin` session with the write scope | a `docker save` tarball of one image tagged `ghcr.io/<org>/<name>:<anything>` — the archive decides the repository, the track decides the tag | pushed as `ghcr.io/<org>/<name>:testing-<build id>` (the id's `+` spelled `-`: a tag no floor ever names) | pushed as `ghcr.io/<org>/<name>:<version>` — what consumers pin | the registry login's: gh's token with `write:packages`, or the one `DEV_REGISTRY_TOKEN` names | `pushed <ref>, …` |

Both leave the scratch untouched: `gem push` uploads the file as it is,
and the engine's image store is the image publisher's own. The image
publisher resolves the engine on first use, not at construction — the
Registry builds every contributed publisher at load, for every command.
A contributed channel the project does not declare accepts every
packageable build, so a project with a gem target *and* a zip target
declares `rubygems: { targets: [<gem>] }` to keep the zip out of it; the
publisher's own check is the backstop, not the selection.

**Options.** What a publisher cannot know from a build or from its
declaration — the destination's identifiers on the store's side — the
channel declares under its own name (`steam:` on the `steam` channel),
carried verbatim as `Lifecycle::Channel#options` and parsed by the
publisher at the start of `publish`, into a typed value of its own
(`SteamChannelOptions`, `EgsChannelOptions`): a missing or malformed key
is refused there, naming the key and the fix, before any archive is
unpacked or any tool run. The options are the publisher's vocabulary, so
`ChannelParser` only checks the shape — a mapping, and never beside a
`run:` — and the publisher documents the keys. Credentials are never
options.

**Unpacking.** A store that takes a directory rather than a file gets it
from `Lifecycle::Unpacker`, the inverse of `Archive`: every form
`package` writes (a zip, a `.tar.zst`, a split set through its
`MANIFEST`) is extracted into a directory of the scratch, which is
**replaced** each time so a file from the previous deploy never rides
along, and the archive itself is never touched.

### The `steam` publisher

The `steam` integration's repository is its publisher
(`Deps::SteamRepository`, `publisher:` on the `steam` entry): the same
client, `steamcmd`, reads a depot (`app_info_print`) and uploads a build
(`run_app_build`), and the same build account is behind both. A project
pinning a Steam app (`steam "SatisfactoryServer", app: 1690800`) has a
`deploy steam` channel, which it configures with:

```yaml
steam:
  desc: Steam depots
  targets: [cellbound-3d-steamworks-win64-release, cellbound-3d-server-linux64-release]
  steam:
    app: 480                                   # the AppID
    depots:                                    # one DepotID per build pattern
      cellbound-3d-steamworks-win64: 481
      cellbound-3d-server-linux64: 482
    branches: { testing: beta, live: default } # optional; these are the defaults
```

Each accepted build must match exactly one `depots:` pattern
(`NoDepotError`, `AmbiguousDepotError`). A deploy unpacks each archive
into `.steam/depots/<DepotID>/`, writes the content builder's scripts
into `.steam/scripts/` (`app_build_<app>.vdf` over one
`depot_build_<id>.vdf` per depot, `Deps::SteamAppBuild` through
`Deps::Vdf`; `BuildOutput` is `.steam/output/`, where steamcmd keeps the
chunk cache the next upload's delta is computed against) and runs
`steamcmd +runscript` on a `0600` script — login, `run_app_build`,
`quit` — so the credentials are on no command line. The **testing**
track sets the build live on the testing branch (`beta` unless
`branches:` says otherwise); the **live** track targets `default`, which
Steam refuses to set live from a script, so the build is uploaded and
the receipt names the Steamworks page where the operator sets it live
(a `branches: { live: <beta branch> }` sets that branch live instead).
The receipt: `steam build <BuildID> of app <app> (depots …) set live on
<branch>`, or `… uploaded — set it live on the default branch in
Steamworks: <url>`. The build account is `dev cred` `steam/username`
(`STEAM_USERNAME`); its password `steam/password` (`STEAM_PASSWORD`),
or, absent, steamcmd's cached login for that account (a CI runner logs
in once interactively, Steam Guard included). A failing steamcmd is
`UploadFailedError` with its last lines; a successful one that reports no
BuildID is `BuildIdNotReportedError`.

### The `egs` publisher

The Epic Games Store has one tool, Epic's **BuildPatchTool**, and no read
side a project would otherwise depend on, so the `egs` integration *is*
the tool: `egs "BuildPatchTool"` in `dependencies.rb` pins the zip Epic
serves (`UrlRepository` — the URL is the universe, TOFU-hashed at `dev
deps update`, verified at install; `url:` names a mirror), and
`EgsIntegration` unpacks it into `~/.dev/egs/BuildPatchTool/<digest>/`
(`dev deps path egs BuildPatchTool`). Pinning the tool is what
contributes the `deploy egs` channel; `Deps::EgsPublisher` is its own
class, since the read side's client (curl) and the write side's (the
tool, under the product's credentials) share nothing. The channel
configures it with:

```yaml
egs:
  targets: [cellbound-3d-win64-release]
  egs:
    organization: o-abc123                   # the Organization ID
    product: p-def456                        # the Product ID
    artifacts:                               # one Artifact per build pattern
      cellbound-3d-win64:
        id: a-789xyz                         # the Artifact ID
        launch: Cellbound3D.exe              # relative to the build root
        args: ""                             # optional
    labels: { testing: Testing, live: Live } # optional; these are the defaults
```

Each accepted build must match exactly one `artifacts:` pattern
(`NoArtifactError`, `AmbiguousArtifactError`) and be for a platform the
store serves — win64 (`Windows`) or macos (`Mac`); a linux64 build is
refused before anything runs (`UnsupportedPlatformError`). Per shipment
the publisher unpacks the archive into `.egs/builds/<build>/`, runs
`BuildPatchTool -mode=UploadBinary` with the build root, `BuildVersion`
the build id, `AppLaunch`/`AppArgs` from the artifact and a `CloudDir`
of `.egs/cloud/<artifact id>/` (kept, so the tool diffs against the
previous upload), then `-mode=LabelBinary` with the track's label —
`Live` is the one players see, so a release's archive takes it and a
working artifact `Testing`, labelled rather than left unlabelled since
Epic deletes unlabelled binaries after a week. The receipt: `egs
<version> → artifact <id>, … labelled <label>`. The product's client is
`dev cred` `egs/client_id` (`EGS_CLIENT_ID`) and `egs/client_secret`
(`EGS_CLIENT_SECRET`); the secret reaches the tool through the
environment variable `-ClientSecretEnvVar` names, never argv. A lock
pinning no `egs` dependency is `NoToolPinnedError` (the channel was
wired by mistake), a pinned tool not yet installed is
`ToolNotInstalledError` ("run dev up"), and a failing tool is
`UploadFailedError` naming the step and carrying its last lines.

### The `ficsit` publisher

**`ficsit`** — the Satisfactory Mod Repository (SMR, ficsit.app),
contributed to every project whose lock pins a mod (`ficsit "SML"`;
[dev#427](https://github.com/d3mlabs/dev/issues/427)). What it takes and
what it does, in SMR's own terms:

| | |
| --- | --- |
| Shipments | one per build, each an **Alpakit per-target zip** — the mod's staged plugin for one target, `<ModRef>.uplugin` at the zip's root and its cooked content under `Content/Paks/<target>/` — which is what a mod target's `packager: as-is` leaves in the store (snappy's `snappy-steam-win64`, `snappy-egs-win64`, `snappy-server-linux64`). The publisher reads two facts from each (`Deps::AlpakitPlugin`): the **mod reference** from the `.uplugin`'s name, the **target** from the paks directory — `Windows`, `WindowsServer` or `LinuxServer` (`Deps::FicsitTarget`, SMR's `AllowedTargets`, which are Unreal's cooked-platform names). Nothing in `dev.yml` names the mod. |
| The merge | the per-target zips become SMR's **multi-target plugin zip** (`Deps::MultiTargetPluginMerger` → `Deps::MultiTargetPlugin`): every entry under its target's directory (`Windows/…`, `LinuxServer/…`), each holding that target's plugin with its `.uplugin`, nothing at the zip's root — the layout SMR's `validateMultiTargetPlugin` accepts and splits back into per-target downloads. Two builds of one target (the Steam and Epic clients are two `Windows` plugins) are **unioned**: their binaries differ and sit side by side; a file both carry must be byte-identical, else the deploy is refused naming the file and both archives (`ConflictingFileError`) — picking one would alter the other build's bytes, which a publisher never does. The archives must be one mod's (`MixedModReferencesError`) staged from one descriptor — SMR reads one version from the zip, so the `.uplugin` must be byte-identical across targets (`DifferingUpluginError`) — and the result under SMR's 1 GB (`PluginTooLargeError`). All of it happens under the channel's scratch (`.ficsit/merge/`, wiped per deploy; the zip is `.ficsit/<ModRef>.zip`); the shipments are never touched. |
| The upload | SMR's chunked upload over its GraphQL API (`Deps::FicsitClient`, `api.ficsit.app/v2/query`): `getModByReference` for the mod's id (a mod SMR does not have is `ModNotFoundError`, before anything is sent), `createVersion`, `uploadVersionPart` in 10 MB parts numbered from 1, `finalizeCreateVersion` with the **stability** the track decides and a changelog naming the builds and their ids, then `checkVersionUploadState` every 10 s for up to 10 minutes until SMR has processed the zip (`ProcessingTimedOutError` past that). SMR's own refusals — a mod not yet approved, a missing AI or network disclosure, a `.uplugin` whose `SemVersion` the mod already has — come back as `FicsitClient::ApiError` in SMR's words. |
| Tracks | `testing` → `beta`, `live` → `release` (`Deps::FicsitStability`, SMR's `VersionStabilities`): an artifact from the store is a version players opt into in the Mod Manager; a release's archive is what everyone gets. `alpha` is never emitted. |
| Credential | the user's **API key** from ficsit.app's settings page: `dev cred get ficsit api_key`, or `FICSIT_API_KEY` in the environment (the key is SMR's raw `Authorization` header value). Prompted once on a terminal and stored; a non-interactive miss names the env var. |
| Receipt | `ficsit: <ModRef> (<targets>) → <stability>, version <version> (<id>), auto-approved` — or `awaiting approval`, when SMR holds the version for a moderator. |

The version string is the `.uplugin`'s `SemVersion`, read by SMR, not
dev: a working-tree build deployed twice without bumping it is refused by
SMR on the second upload, in its words.

### The `brew` publisher

`Deps::BrewPublisher` is the `brew` entry's write side, the one built-in over a store that is a git remote: a project whose
lock pins anything from a tap through brew (dev's own `ruby` from
`d3mlabs/d3mlabs`) gets a `deploy brew` channel, and declaring it in
`dev.yml` with an accept set and no `run:` configures it. It ships
**releases only**: a Homebrew formula points at a release asset, never
at a store file, so a shipment of store provenance is refused
(`WorkingArtifactError`) and the testing track has no meaning for it —
`dev deploy brew --release <version>` is the only form.

One formula per shipment, named as the build (`Formula/<name>.rb`):
dev's `dev-core` and `dev` builds land in `Formula/dev-core.rb` and
`Formula/dev.rb`. The publisher rewrites only the formula's **stable
spec** — the first `url`/`sha256` pair (`Deps::FormulaFile`), never a
`resource`'s or a bottle's — with the asset's download url as the forge
reports it (`GithubReleases#asset_url`, from `gh release view --json
assets`; dev spells no url layout of GitHub's) and the digest
`release.json` carries for that archive (the shipment's; nothing is
downloaded twice). A formula already at that pair is left alone; when
none moved the receipt says `<tap> already points at <tag>: <names>` and
no commit is made. Otherwise one commit, `<names>: <version>`, pushed to
the tap's default branch, and the receipt is `<tap>@<sha>: <names> →
<tag>`.

The **destination** is the lock's: the taps of the brew-family pins
(their `tap:` metadata), which must be exactly one (`NoTapError`,
`AmbiguousTapError`) — a channel has no options yet, and the lock is
where dev already records which tap the project trusts. The tap is
cloned into the channel's **scratch** (K5: `<data root>/artifacts/
<project>/.brew/<user>/homebrew-<repo>`, brew's own layout), fetched
and hard-reset to the remote's default branch on every run
(`Deps::TapClone`), so there is no sibling checkout to keep
fast-forwarded and a half-done run leaves nothing to clean. The
formula's body — `depends_on`, `install`, `caveats` — stays
hand-authored in the tap; the publisher never reads it.

Why its own class rather than `publish` on `BrewRepository`: K5 merges
read and write sides when they share a client and its auth. Brew's read
side is `brew info` over the local brew; the write side is git and `gh`
over a clone — nothing shared, so a shared class would be two classes
in one file.

## The dependency graph

Each verb needs exactly what the one before it leaves, and names the
missing step rather than performing it:

| Verb | Needs | When missing |
| --- | --- | --- |
| `build <build>` | the build's environment, able to produce its platform — here, or on a host the [remote dispatch](#the-remote-dispatch) can reach | reported at load and left unbound (an image without the `target_platforms`: refuses until `dev deps update`), or refused at the verb: a host-placed build whose platform this machine is not (`--runner` sends it to one that is); an environment this machine is not goes to a runner, else to the project's container — which needs the engine up (`ProjectContainer::EngineUnavailableError`: `dev up` brings it up) |
| `package <build>` | a current build | makes it (make-like): the builder runs when the artifact is not current, `--no-build` trusts the install |
| `deploy <channel>` | an artifact per accepted (target, platform) in the store, a channel, the channel's environment, a protocol (`run:` or a publisher the lock contributes under the channel's name); to record, a repo `gh` can reach with `deployments: write` | "`dev package <build>` first" — never builds; a channel exists or `deploy` does not; an unbound environment (the lock unreadable) lists without a column and refuses until `dev deps update`; a channel with neither protocol is refused at load, both fixes named; a record the forge refuses fails after the shipped lines, naming the refusal |
| `deploy <channel> --release V` | a release `dev release V` cut, carrying an archive of each accepted (target, platform); a repo `gh` can reach with `contents: read` for the download | "`dev release V` cuts it" for a tag with no release; a build the release has no archive of is refused — the store never substitutes, deploy adds nothing to a release; a download whose digest is not `release.json`'s is removed and refused, nothing shipped |
| `deploy --release V` | the above for every channel | stops at the first channel that refuses, the earlier ones deployed and recorded; name the channels to ship the rest |
| `deploy status [--release V]` | a channel, a repo `gh` can reach | a channel exists or `deploy` does not; the forge's refusal is the command's error |
| `release <version>` | a clean checkout on a branch with `origin`, the version not yet cut (or cut on HEAD: a resume), `release:` naming packageable builds; a repo `gh` can reach with `contents: write` | refuses before anything moves (dirty, detached, the tag elsewhere); packages each release build **at the tag** itself, so staleness cannot arise; a tag pushed with no release yet is what the retry resumes; the forge's refusal is the command's error |

## Dispatch resolution

Where a verb's seam runs is decided per build, before anything runs, from
the target's `environment:` bound against the lock at load
(`Dev::PlacementBinder#bind_targets` → one `Dev::TargetPlacement` per
target, a `Placement::Host` or `Placement::Image` per declared platform).
A channel's protocol is placed the same way from the channel's
`environment:` (`#bind_channels` → one `Placement` per channel), resolved
under the same host rule when `deploy` runs.

**At load**, for every build with a platform, the environment named for
that platform must produce it: an image through the `target_platforms`
its lock entry carries (`ImageDoesNotProduceError` otherwise, with the
fix named — reported, not fatal, see step 1 below, because the lock
entry lags the block until the re-lock); `host` produces the platform
this machine is, which cannot be a load-time refusal because the same
`dev.yml` loads on a Mac and on the Linux box. A build with no platform
has nothing to check.

**At the verb**, `Dev::BuildDispatcher` answers for the selected build:

1. Is the target bound at all? When the lock could not place the builds
   at load (a pin locked by another dev's template, a retired
   `build-deps.lock`, an image pinned before its block declared the
   `target_platforms` a build now asks of it) nothing is placed: the
   error is printed once on stderr, `dev help build` lists the builds
   without an environment column and the verb refuses
   (`UnboundTargetError`) until `dev deps update` re-locks, since that
   remediation is served by the same tree.
2. Can this host produce the build where it is placed?
   `TargetPlacement#assert_buildable_here!`: a host-placed `linux64`
   build on a Mac is refused (`HostDoesNotProduceError`) and marked
   `(linux64 only)` in the listing; an image-placed build defers to the
   image's declaration, already checked. Skipped under `--runner` and
   `--container`: that host produces the build, not this one.
3. `Dev::DispatchResolver#resolve(placement, runner:, container:)` under
   the host rule
   ([README: The host rule](../README.md#the-host-rule-native-when-provisioned-from-the-image-inside-it-otherwise)),
   then against the hosts the remote dispatch can reach, in this order:

| Placement | This machine | Dispatch |
| --- | --- | --- |
| any | both `--runner` and `--container` given | refused, `ConflictingDispatchFlagsError`: one host per verb |
| any | `--runner <label>` given | **remote** to that label, whatever the placement — a Win64 build-check on the hosted pool from a box that could build it natively |
| `host` | `--container` given | refused, `NoContainerForHostError`: a host-placed build has no image to run in |
| `host` | any | **native** — the seam runs here |
| image *I* | `--container` given, inside *I*'s container | **native** (a container of another image is `ContainerDriftError`) |
| image *I* | `--container` given | **remote** to the project's container of *I*, whatever the host rule says — a Linux-image build on the box forced inside |
| image *I* | provisioned from *I* (the box, a hosted runner) | **native** |
| image *I* | inside *I*'s container | **native** (a container of another image is `ContainerDriftError`) |
| image *I* | neither (a Mac), `lifecycle.runner` set | **remote** to that label (`dev config set lifecycle.runner <label>`, or `DEV_LIFECYCLE_RUNNER`) |
| image *I* | neither, the repo's enrolled runner online | **remote** to the enrolled runner, under the repo's label |
| image *I* | neither, nothing standing | **remote** to the project's **container** of *I* ([dev#421](https://github.com/d3mlabs/dev/issues/421)): the last resort, so a verb with an image placement always has a host — the container is brought up by `dev up`, and a verb that reaches for it while the engine is down is refused before anything is pushed (`ProjectContainer::EngineUnavailableError`) |
| any | inside an Actions job, and the row above would be remote | refused, `DispatchFromJobError`: a job never dispatches a job (see [the loop guard](#the-remote-dispatch)) |

**The enrolled runner** is the host the remote dispatch resolves to
when nothing standing names another and before the container (K8:
native, else the enrolled runner, else the container). It is what bare `dev runner register`
makes, declared nowhere: a runner at the **repo's scope** carrying the
**repo's name as label** — both derived from the one `gh repo view`
answer by `Dev::EnrolledRunner` (`d3mlabs/cellbound-3d` → scope
`d3mlabs/cellbound-3d`, label `cellbound-3d`; lowercased, dashes kept;
dev.yml `name:` never enters). Whether one is **available** is the
Actions API's answer, read when the verb runs and recorded nowhere
(`Dev::EnrolledRunnerLookup#available` →
`RunnerRegistry#available(scope:, label:)`): an online runner at that
scope carrying that label. Busy counts — GitHub queues the job; offline
does not — a registration nothing runs is not a host to build on; a
runner the org enrolled under the same label is a pool for `--runner
<label>`, not the repo's; and GitHub unreachable raises
(`RunnerRegistry::QueryError`) rather than reading as "no runner", since
a remote dispatch needs GitHub for the snapshot push and the run anyway.

The environment column of `dev help build` is the same resolution read
for display: `host`; `cellbound-3d-linux` when this machine runs it
natively; `cellbound-3d-linux (remote)` when the verb would leave for a
host that is the image — a verb never enters a container, so the
`(container)` a project command shows does not apply, and *which* host
is decided when the verb runs, never asked of the forge by help.

**The template.** A verb is a `Dev::LifecycleCommand`, run by
`Dev::LifecycleExecutor` as *before → seam → after*: `before` consumes
the argv into the build, resolves the dispatch and hands it the
**invocation** (`Lifecycle::VerbInvocation`: the verb as a remote host
would run it) and a block that builds the env. `Dispatch::Native` runs
the block and returns `Run(env)` for the seam; `Dispatch::Remote` never
runs it — the env is the host's to resolve, over the host's tree and
store — and returns `Done` once the verb has run there, so `deploy` from
a Mac with an empty store does not refuse for an artifact that lives on
the box. The seam runs over env only; `after` stamps and reports. Always
spawn-and-wait — never an exec-replace, which would make `after`
unreachable (`.cursor/skills/learnings/command-runner-exec`). A failure
in the seam short-circuits `after`.

## The remote dispatch

`Dispatch::Remote` runs a verb on a host that has the build's
environment ([dev#420](https://github.com/d3mlabs/dev/issues/420); K7,
K8, K10): [the sync step](#the-sync-step) pushes the working tree as a
snapshot branch, one dim line says where the verb went and from which
commit, a **transport** runs the invocation there and returns with its
verdict, the branch is deleted. The path is written once against the
sealed `Dev::Transport` interface (`runner`, `destination`,
`assert_ready!`, `run(invocation, snapshot:)`); what differs per host is
how the verb is invoked and watched:

- `Transport::ActionsRunner` — a GitHub Actions runner carrying a label,
  reached through dev's generic workflow ([dev#420](https://github.com/d3mlabs/dev/issues/420)).
- `Transport::LocalContainer` — the project's container of the build's
  image, the last host in the resolution order and the one `--container`
  forces ([dev#421](https://github.com/d3mlabs/dev/issues/421);
  [ADR-0008](DECISIONS.md#adr-0008--a-data-root-belongs-to-a-build-host):
  *the container is a remote that happens to be local*). The verb runs by
  `docker exec` into the persisted image's service container (or a
  one-shot `docker run --rm` of a non-persisted image) as the same program
  every container runs for dev (`Dev::ContainerWorkspace#script`): bring
  the container's **own workspace** — a checkout of its own under its data
  root, `/var/lib/dev/workspaces/<checkout>-<workspace id>`, created on the
  first verb and kept warm after (`Intermediate/`, `Binaries/`, the DDC
  are ignored files, which `git clean -fd` leaves alone) — to the snapshot
  (`git fetch` of the branch over HTTPS with the container's own `gh`
  credential helper, `git reset --hard <sha>`, `git clean -fd`), then
  `exec dev <verb words>` there. Nothing of the host's checkout is
  mounted: `/project` is gone, and the snapshot branch is the one way the
  tree crosses, for a container as for a runner. The container's exit
  status is the verdict (`ContainerVerbFailedError` carrying it). The
  snapshot's `.shadowenv.d/` is the workspace's own (an ignored
  directory, so it too survives the reset) and the container's `dev up`
  fills it. `dev up` installs the container's dependencies over the same
  step — a snapshot synced for `container`, fetched into the same
  workspace — so the first verb finds the workspace warm.

**The crossing line.** `→ on <runner>, snapshot <sha>` for a runner,
`→ in <image> (container), snapshot <sha>` for the container (dim;
`Cli::Ui#print_remote_crossing(destination:, snapshot:)`, the destination
the transport's own), the counterpart of `→ in <image>` when a project
command enters a container: one line, so the operator knows the next
output is another host's. The Actions transport then names the run's
page — ``dispatched `dev build cellbound-3d-win64-dev` on
ue-engine-hosted: https://…/actions/runs/42`` — and streams `gh run
watch` to the terminal; the container's output is the terminal's
directly.

**The generic workflow.** dev ships `share/workflows/dev-lifecycle.yml`;
a project copies it verbatim to `.github/workflows/dev-lifecycle.yml` and
commits it — a workflow is the project's to review, so dev never writes
it, and a dispatch that finds it missing refuses before anything is
pushed (`LifecycleWorkflow::WorkflowMissingError`) with the `cp` named,
source path included. Its contract is `Lifecycle::LifecycleWorkflow`:

| Input | What it carries |
| --- | --- |
| `verbs` | one or several dev invocations, comma-separated, exactly as typed after `dev` (`package cellbound-3d-win64-dev --no-build`); the job word-splits each and runs `dev <words>` in order. Hence `VerbInvocation` refuses a word carrying a comma or whitespace. |
| `runner` | the label the job demands beside `self-hosted`: `runs-on: [self-hosted, <runner>]` |
| `fetch` | whether to upload the packaged artifact as a workflow artifact named after the build (see `--fetch`) |

The job: `actions/checkout` of the snapshot branch, dev put on PATH
(the brew prefix that holds it), `dev up`, the verbs, the upload when
asked. Only `workflow_dispatch` triggers it, so a snapshot push runs
nothing on its own.

**Finding the run.** `workflow_dispatch` answers 204 with no run id, so
the run is **located by its branch**: the snapshot branch is unique to
this dispatch, and `gh run list --workflow dev-lifecycle.yml --branch
<branch> --event workflow_dispatch --limit 1` is the one run GitHub made
of it — polled up to 30 × 2 s while the forge registers it
(`WorkflowRuns::RunNotListedError` after). No diffing of run lists
before and after, no guessing by time. `gh run watch` follows it;
`gh run view` reads the verdict; a run that is not `completed` +
`success` is `Transport::ActionsRunner::RemoteVerbFailedError` naming the
verb, the label, GitHub's conclusion and the page.

**`--runner <label>`** on `build`, `package` and `deploy <channel>`
forces the remote dispatch to that label whatever the placement — a
pool the org enrolled (`ue-engine-hosted`), another repo's runner, the
repo's own. **`--container`** forces the project's container of the
build's image the same way — a Linux-image build run inside on a box
that could build it natively, to check the image — and is refused for a
host-placed build (`NoContainerForHostError`: there is no image to run
in) and together with `--runner` (`ConflictingDispatchFlagsError`).
**`lifecycle.runner`** (`dev config set lifecycle.runner <label>`;
`DEV_LIFECYCLE_RUNNER`) is the standing form, read before the enrolled
runner when a verb must leave; none of the three is consulted while the
verb can run natively.

**The invocation re-spelled.** The host runs the verb as the operator
typed it, with the build fully qualified (`build cellbound-3d-win64-dev`,
never a default the host would resolve differently), the seam's flags
kept (`--no-build`; `deploy`'s `--config`, `--allow-stale`, `--force`,
`--dry-run`) and the dispatch's flags consumed (`--runner`,
`--container`, `--fetch`): a `--runner` that crossed would make the host
dispatch again.

**`--fetch`** (`package` only) brings the artifact back: the remote
`dev package` names what it stamped on the step's outputs
(`Lifecycle::StepOutputs`: `artifact=<build>`, `artifact_files=<archive,
build-id.json>`), the workflow uploads those files as a workflow
artifact named after the build, and the operator's side runs `gh run
download <id> --name <build> --dir <store dir of the build>` — so the
files land where `dev deploy` here reads them, as if packaged here.
The default is the opposite (K10): a multi-GB archive over a Mac's
uplink is wanted only when a deploy leaves from the Mac; the box deploys
from its own store. From the **container**, `--fetch` is a `docker cp`
out of a one-shot container of the image — the container's store and the
host's are two volumes on a Mac — into the same store directory; on a
Linux host the container's data root *is* the host's (the dev#308 bind
mount), so the artifact is already there and the fetch is a no-op.

**The loop guard.** A verb running inside an Actions job
(`GITHUB_ACTIONS=true`, `Dev::ActionsJobContext`) never dispatches
remotely: the runner was told to run the verb, and a runner that finds
itself not to be the build's environment is misprovisioned — the answer
is `DispatchFromJobError` saying so, not a job dispatching a job onto
itself or between two runners forever.

## The sync step

A remote dispatch runs the verb on a host that has the build's
environment — an enrolled runner ([dev#420](https://github.com/d3mlabs/dev/issues/420)),
or the project's container as the last host in the order
([dev#421](https://github.com/d3mlabs/dev/issues/421); its branches are
synced for `container`). What that host builds is the operator's
**working tree**, uncommitted changes included, and the one transport
every host already has to it is the project's GitHub remote (K7 in the
plan; [ADR-0008](DECISIONS.md#adr-0008--a-data-root-belongs-to-a-build-host)):
the container has no bind mount of the checkout and fetches like any
other host. `Lifecycle::SnapshotSync#sync(runner:) { |snapshot| … }` is
that step, in order:

1. **Refuse while nothing has left the machine** if a project workflow
   would run on the push. `Lifecycle::WorkflowTriggers` reads
   `.github/workflows/*.yml` and answers GitHub's own question for the
   branch about to be pushed: an `on: push` with no `branches` /
   `branches-ignore` / `tags` filter fires for every branch; a `branches`
   list fires when a pattern matches (`!` negations in order; `**` as
   GitHub reads it); a `branches-ignore` list fires when none does; a
   trigger filtered on tags only never fires for a branch; `paths` do not
   narrow branches. One firing workflow is
   `UnfilteredPushTriggerError`, naming every such file and both fixes:
   filter on the project's branches (`on: push: branches: [main]`) or
   exclude dev's namespace (`branches-ignore: ['dev/build/**']`). Without
   this, every remote `dev package` would also be a CI run on a tree
   nobody committed.
2. **Commit the working tree through a temporary index**
   (`Lifecycle::SnapshotCommit`): `GIT_INDEX_FILE` pointed at a scratch
   file, seeded from HEAD, `git add --all` over it — tracked files as
   modified, new files, deletions, `.gitignore` honoured, a tracked file
   `.gitignore` also names kept — then `write-tree` and `commit-tree`
   with HEAD as parent. HEAD, the branch and the operator's own index
   never move. A **clean** tree snapshots to HEAD itself: its tree is
   HEAD's, and the artifact the runner stamps then names the commit the
   operator is at. A repository with no commit yet snapshots to a
   parentless commit. The commit's identity is dev's own, so the step
   works on a host with no `user.*` configured.
3. **Push** the commit to `refs/heads/dev/build/<runner>/<id>` on
   `origin` (`Lifecycle::SnapshotBranches#push`: `--force`, the
   namespace is dev's; `--no-verify`, a pre-push hook guards the
   project's branches, not a throwaway one; never a prompt). A branch
   rather than a hidden ref because `workflow_dispatch` accepts only a
   branch or a tag, and a branch rather than a tag because a tag cannot
   be force-moved for a retry and `git fetch --tags` would drag every
   snapshot into every clone.
4. **Hand the snapshot to the dispatch** — the block receives a
   `Lifecycle::Snapshot` (the sha, the branch): the `ref` the
   `workflow_dispatch` names, the sha the crossing line prints and the
   container fetches.
5. **Delete the branch** when the block returns, however it returns.
   Best-effort: a dispatch that succeeded is not failed by a lost
   connection afterwards; a delete the remote refused is reported with
   the prune named as the fallback.

**The branch grammar.** `dev/build/<runner>/<utc instant>-<nonce>` —
`dev/build/cellbound-3d/20261105T173000Z-a1b2c3`. The runner segment is
the label the dispatch targets (one ref segment: letters, digits, `.`,
`_`, `-`; `InvalidRunnerLabelError` otherwise), the instant is spelled
as every instant in dev's names (`BuildId`'s), the nonce keeps two
snapshots minted in one second apart. `SnapshotBranch.parse` reads a
branch back from its short name or its full ref, and a name under the
namespace outside the grammar is not dev's
(`MalformedSnapshotBranchError`; the prune leaves it alone).

**Retention.** A branch outlives its dispatch only when the delete did
not happen — a killed dev, a lost connection, a read-only credential.
`dev cache gc` prunes every `dev/build/*` branch on `origin` **older than
seven days** (`SnapshotBranches::MAX_AGE_DAYS`), reading each age from
the name — so the prune is one `git ls-remote` and one `git push
--delete`, no fetch of the snapshots' objects, no API call per branch.
It is one more tier of the gc, best-effort like the others: an `origin`
that cannot be listed or written is reported and skipped, never a
failure of the gc. A workflow only *schedules* `dev cache gc`; nothing
else prunes the namespace.

**Trust.** A snapshot-branch build is unreviewed code running on the
host as its job user — the trust `dev s` extends today; the runbook
says so.

## Adding a port implementation

A new builder implements `Lifecycle::Builder` (`build`, `name`,
`version`), a new packager `Lifecycle::Packager` (`package`), a new
publisher `Lifecycle::Publisher` (`publish`); a builder or packager is
wired in `Lifecycle::Ports` from a new `BuilderSpec` / `PackagerSpec`
variant, and nowhere else. An integration's publisher needs no new spec:
it is set as `publisher:` on the integration's `Deps::Registry::Entry`
(with `publisher_needs:` naming the kwargs its constructor takes from
the composition context — `project_root` today — and `channel:` when the
destination is not called as the type is: `rubygems`, `ghcr`; `taps` for `brew`), and every
project whose lock reaches the entry gets the channel; the registry's
consistency test fails on a `*_publisher.rb` no entry wires, and on two
entries claiming one channel. `PublisherSpec::Integration` is
the one reference the parser emits for "the lock's publisher of this
name". The verbs, the selectors, the dispatcher and the store do not
change: they see ports, builds and channels, never scripts, formats or
endpoints.
