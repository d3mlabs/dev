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

Seven nouns, each one class, none playing two roles.

| Concept | Class | What it is |
| --- | --- | --- |
| Target | `Lifecycle::Target` | What can be built — the content axis (a client, a server, a gem) — with the axes it varies over (`platforms`, `configs`), a builder spec, a packager spec and an environment. Declared in `dev.yml`. |
| Build | `Lifecycle::Build` | One point of target × platform × config, fully qualified, with one name. Derived, never declared. |
| Build pattern | `Lifecycle::BuildPattern` | A build name with an axis left out; names a set, and has one *default build* (the target's first of each omitted axis). What the verbs' positional parses to. |
| Artifact | `Lifecycle::Artifact` | What `package` makes of one build: the archive beside its `build-id.json`, in the store. A directory without the manifest is not one. |
| Store | `Lifecycle::Store` | `<data root>/artifacts/<project>/<build>/` — one directory per declared build, holding the install, the archive and the manifest. Keyed by the project's `name:`, never the checkout. |
| Channel | `Lifecycle::Channel` | Where artifacts ship to: a name, the builds it **accepts** (patterns in the build grammar) and a publisher spec. Declared as a child of `commands: deploy:`, or contributed by the lock under an integration's name. |
| Publisher | `Lifecycle::Publisher` | The channel's protocol — the port `deploy` runs over the selected artifacts, on a track, with a scratch. `ScriptPublisher` is the `run:` form; an integration publisher is the integration's write side, declared on its registry entry (`publisher:`, [dev#422](https://github.com/d3mlabs/dev/issues/422)). |
| Track | `Lifecycle::Track` | Which of a channel's two tracks a deploy ships on — `testing` from the store, `live` from a release ([dev#425](https://github.com/d3mlabs/dev/issues/425)). Decided by the source, never the operator. |
| Snapshot | `Lifecycle::Snapshot` | The working tree as a remote build host can reach it: a commit made through a temporary index, on its `Lifecycle::SnapshotBranch` (`dev/build/<runner>/<id>`) at `origin`, for as long as a remote dispatch needs it. See [The sync step](#the-sync-step). |

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
      steam:
        desc: Steam depots
        targets: [cellbound-3d-steamworks-win64-release, cellbound-3d-server-linux64-release]
        run: ./bin/steam-upload
      ficsit:                             # no run: — the lock's SML dependency publishes
        targets: [snappy-steam]
```

| Key | Meaning |
| --- | --- |
| `desc` | One line; what `dev help deploy` shows beside the channel. |
| `targets` | The **accept set**: a non-empty list of builds or patterns in the build grammar, parsed at load (`BuildPattern.parse`), so a name no target spells is refused before anything runs. |
| `run` | The protocol's script form: a shell command run at the repo root once per archive, with the env contract below. Omitted, the protocol is the publisher the lock contributes under the channel's name (`PublisherSpec::Integration`). |
| `environment` | Where the script runs — a command's key, values and binding (`Dev::PlacementBinder#bind_channels`). Needs `run:`; an integration publisher is dev's own code and is placed on the host. |

Load-time rules: `deploy` itself may carry no `run:` (`DeployBodyError`)
and must have a child (`NoChannelsError`); a child must be a mapping
(`InvalidChannelError`) with `targets:` (`ChannelAcceptsError`), may not
carry `environment:` without `run:` (`ChannelEnvironmentError`), may not
have `commands:` of its own (`ChannelChildrenError`) and may not be named
`help` (`ReservedChannelNameError`). A `deploy` child carrying `targets:`
in a project without targets is refused (`ChannelWithoutTargetsError`):
there is no build for it to accept. Without targets, `deploy` stays a
plain project command, children included.

**The lock contributes channels** ([dev#422](https://github.com/d3mlabs/dev/issues/422)).
An integration with a write side declares it on its registry entry as a
`publisher:` port (`Deps::Registry::Entry`, beside `integration:` — the
install is the read side, the publisher the write side, both the same
dependency, [ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel)),
and every project whose lock reaches that entry — directly or through an
`install_alias`, as `ruby:` pins reach brew — gets a `deploy` channel of
the entry's name (`Dev::ProjectPublishers`). Nothing in `dev.yml` names a
publisher. The declared and the contributed sets merge by name in
`Dev::ChannelBinder`, at the composition root, before the command tree
exists — the "third merge case" of `CommandRepository#merge`, applied to
channels since `deploy`'s children never land on the builtin's slot:

| Declared | Contributed | Result |
| --- | --- | --- |
| with `run:` | any | the script **replaces** the publisher; dev's stage still selects, checks and records |
| without `run:` | a publisher of that name | the declaration **configures** it: `targets:` is the accept set, `desc` is the row, the protocol is the integration's |
| without `run:` | none | refused at load (`ChannelBinder::ChannelProtocolError`), naming both fixes: declare `run:`, or depend on an integration whose publisher knows the endpoint |
| — | a publisher | the channel appears as the lock's: every packageable build accepted, a stock `desc`; a project with nothing packageable gets no row |

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
| Publisher | `Lifecycle::Publisher#publish(artifacts, channel:, track:, scratch:)` | `ScriptPublisher`; the lock's integration publishers | a channel's `run: <command>`; a registry entry's `publisher:` |

A third port, the **publisher**, is the channel's: it takes the
artifacts `deploy` selected and ships them, never choosing on its own and
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
| `DEV_ARTIFACT` | a channel's `run:` | the archive **file** — the path with its extension, as the store holds it |
| `DEV_CHANNEL` | a channel's `run:` | the channel's name |
| `DEV_TRACK` | a channel's `run:` | `testing` / `live` — the track this deploy ships on |
| `DEV_SCRATCH` | a channel's `run:` | the channel's scratch directory, created before the first run and kept between deploys |
| `DEV_BUILD` | a channel's `run:` | the build's full name (`cellbound-3d-win64-release`) |
| `DEV_BUILD_ID` | a channel's `run:` | the manifest's build id (`1.4.0+0123456789ab`) |
| `DEV_SHA` | a channel's `run:` | the commit the artifact was packaged at; `unknown` outside git |
| `DEV_DIRTY` | a channel's `run:` | `true` / `false` — whether that tree had uncommitted changes |
| `DEV_PACKAGED_AT` | a channel's `run:` | the UTC instant (`20261104T123000Z`) |
| `DEV_ARCHIVE_SHA256` | a channel's `run:` | the archive's digest as stamped |

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
| `deploy <channel> [BUILD] [--config C] [--allow-stale] [--force] [--dry-run]` | a channel exists — declared under `commands: deploy:` or contributed by the lock | the channel's accepted artifacts, from the store | the channel's publisher, over the selection, on the testing track |
| `release <version>` | a `release:` block | — | milestone D |

A project without targets lists neither `build` nor `package`, and
`dev build` there is "command not found", not "no targets declared";
one without a channel lists no `deploy`. `dev help build` lists every
build with its target's `desc` and its environment; `dev help package`
lists the shippable ones. Both verbs complete every pattern
(`cellbound-3d`, `cellbound-3d-dev`, …) and every build. `deploy` is a
group whose children are the channels (`Dev::Builtins::DeployCommand`,
one per channel): bare `dev deploy` prints the channels, `dev help
deploy` lists each with its environment column, its accept set expanded
to builds (`Accepts: …`) and its protocol's source (`Protocol: run:
./bin/stage`, `Protocol: publisher: steam`), and a channel completes its
accept patterns and the builds they span.

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

### What `deploy` does

`deploy` never builds (K4): it ships what `package` left in the store,
and refuses — naming the `dev package` that would fix it — when that is
not enough. For `dev deploy <channel> [BUILD]`, `Dev::DeploySelector`
decides what ships, in order:

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

Then the verb's template: `before` resolves where the protocol runs (the
channel's `environment:` under the host rule), reads the tree once,
consumes the argv into the selection, takes the channel's publisher from
`Lifecycle::Ports`, and fixes the track — **testing**, as every deploy
from the store is — and the channel's scratch (`Store#scratch`); the
seam is the publisher, over the whole selection in one call —
`ScriptPublisher` creates the scratch and runs the `run:` line at the
repo root once per archive, with `Lifecycle::ScriptEnv.for_deploy`'s
env, and stops at the first nonzero exit (`DeployScriptFailedError`, the
archive and code named; the ones before it shipped); an integration
publisher ships its own way — skipped under `--dry-run`; `after` prints
one line per artifact (`deployed <build> (<build id>) → <channel>
(<track>): <archive>`, `would deploy …` under `--dry-run`, `— stale,
shipped under --allow-stale` when it was). The receipt as a GitHub
Deployment is [dev#423](https://github.com/d3mlabs/dev/issues/423).

## The channel contract

A channel is a destination; its **publisher** is the protocol that
reaches it. Two kinds share one interface,
`Lifecycle::Publisher#publish(artifacts, channel:, track:, scratch:)`:

| Publisher | Declared as | Knows |
| --- | --- | --- |
| `ScriptPublisher` | the channel's `run:` | nothing but its env: the script owns the endpoint, the credentials, the tool |
| an integration publisher | the integration's registry entry (`publisher:`), reached by the project's lock; the channel is the entry's name | the endpoint, the app id and depots, the release asset layout — from the integration's declaration, not from `dev.yml` |

Both obey two constraints, which is what makes the verb the same over
either:

- **A publisher reads the archive and never rewrites it.** The file in
  the store is what `build-id.json`'s `archive_sha256` says, before and
  after a deploy; a channel that needs another layout copies into its
  **scratch** — `<data root>/artifacts/<project>/.<channel>/`, a
  dot-directory beside the builds so it never reads as one, created
  before the publisher runs and kept between deploys (an unpacked tree
  Steam's content builder can diff against, SMR's staged upload).
- **A publisher ships what the verb selected, never selecting on its
  own.** The accept set, the config choice, the staleness and force rules
  are `DeploySelector`'s and identical for every protocol; a publisher
  gets the artifacts, in order, one call per deploy.

Credentials are the publisher's concern — the project's `dev cred` store
or the script's environment — never `dev.yml`'s.

**Tracks.** A channel has two, `Lifecycle::Track`, and the publisher
maps them onto its own (Steam's beta branch and default branch, SMR's
unreleased and released states, a staging rsync's one); which one a
deploy ships on is the **source's** decision, never the operator's: an
artifact from the store goes to `testing`, an archive of a release
(`deploy --release`, [dev#425](https://github.com/d3mlabs/dev/issues/425))
to `live`. That is the whole statement of "irreversible channel": a
deploy from the store never touches live, and nothing in `dev.yml` can
change it. The **receipt** is [dev#423](https://github.com/d3mlabs/dev/issues/423).

**Where a publisher comes from.** The `publisher:` on a
`Deps::Registry::Entry` is the integration's write side, the way
`integration:` is its install: one dependency, both directions
([ADR-0010](DECISIONS.md#adr-0010--the-verb-follows-the-channel)). The
Registry builds one instance per publishing entry the lock reaches
(`Registry.publishers`), with the kwargs the entry's `publisher_needs`
asks for; `Dev::ProjectPublishers` reads the lock once and asks; the
Runner hands the table to `ChannelBinder` (the merge) and to `Ports` (the
lookup). No built-in entry publishes yet — the first are
[dev#426](https://github.com/d3mlabs/dev/issues/426)–[#429](https://github.com/d3mlabs/dev/issues/429);
an external integration's publisher arrives through
[dev#300](https://github.com/d3mlabs/dev/issues/300)'s integration gems.

## The dependency graph

Each verb needs exactly what the one before it leaves, and names the
missing step rather than performing it:

| Verb | Needs | When missing |
| --- | --- | --- |
| `build <build>` | the build's environment, able to produce its platform | reported at load and left unbound (an image without the `target_platforms`: refuses until `dev deps update`), or refused at the verb (a host-placed build whose platform this machine is not; an environment this machine is not, until milestone B's remote dispatch — an enrolled runner or the project's container) |
| `package <build>` | a current build | makes it (make-like): the builder runs when the artifact is not current, `--no-build` trusts the install |
| `deploy <channel>` | an artifact per accepted (target, platform) in the store, a channel, the channel's environment, a protocol (`run:` or a publisher the lock contributes under the channel's name) | "`dev package <build>` first" — never builds; a channel exists or `deploy` does not; an unbound environment (the lock unreadable) lists without a column and refuses until `dev deps update`; a channel with neither protocol is refused at load, both fixes named |
| `release <version>` (milestone D) | the release's targets packaged at the tag | packages at the tag, so staleness cannot arise |

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
   image's declaration, already checked.
3. `Dev::DispatchResolver#resolve(placement)` under the host rule
   ([README: The host rule](../README.md#the-host-rule-native-when-provisioned-from-the-image-inside-it-otherwise)):

| Placement | This machine | Dispatch |
| --- | --- | --- |
| `host` | any | **native** — the seam runs here |
| image *I* | provisioned from *I* (the box, a hosted runner) | **native** |
| image *I* | inside *I*'s container | **native** (a container of another image is `ContainerDriftError`) |
| image *I* | neither (a Mac) | refused, `RemoteDispatchUnavailableError`, with the hosts that would do named — until milestone B's remote dispatch (a [snapshot branch](#the-sync-step) run on an enrolled runner, or in the project's container as the degenerate runner) |

**The enrolled runner** is the first host the remote dispatch will
resolve to (K8: native, else the enrolled runner, else the container).
It is what bare `dev runner register` makes, declared nowhere: a runner
at the **repo's scope** carrying the **repo's name as label** — both
derived from the one `gh repo view` answer by `Dev::EnrolledRunner`
(`d3mlabs/cellbound-3d` → scope `d3mlabs/cellbound-3d`, label
`cellbound-3d`; lowercased, dashes kept; dev.yml `name:` never enters).
Whether one is **available** is the Actions API's answer, read when the
verb runs and recorded nowhere (`Dev::EnrolledRunnerLookup#available` →
`RunnerRegistry#available(scope:, label:)`): an online runner at that
scope carrying that label. Busy counts — GitHub queues the job; offline
does not — a registration nothing runs is not a host to build on; a
runner the org enrolled under the same label is a pool for `--runner
<label>`, not the repo's; and GitHub unreachable raises
(`RunnerRegistry::QueryError`) rather than reading as "no runner", since
a remote dispatch needs GitHub for the snapshot push and the run anyway.

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

## The sync step

A remote dispatch runs the verb on a host that has the build's
environment — an enrolled runner ([dev#420](https://github.com/d3mlabs/dev/issues/420)),
or the project's container as the degenerate runner
([dev#421](https://github.com/d3mlabs/dev/issues/421)). What that host
builds is the operator's **working tree**, uncommitted changes included,
and the one transport every host already has to it is the project's
GitHub remote (K7 in the plan; [ADR-0008](DECISIONS.md#adr-0008--a-data-root-belongs-to-a-build-host)).
`Lifecycle::SnapshotSync#sync(runner:) { |snapshot| … }` is that step,
in order:

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
the composition context — `project_root` today), and every project whose
lock reaches the entry gets the channel; `PublisherSpec::Integration` is
the one reference the parser emits for "the lock's publisher of this
name". The verbs, the selectors, the dispatcher and the store do not
change: they see ports, builds and channels, never scripts, formats or
endpoints.
