# The lifecycle

How `dev build`, `dev package`, `dev deploy` and `dev release` act on a
project's targets and channels: what each verb does, what it leaves
behind, where it runs, and what it refuses. The declarations themselves
— `targets:`, `commands: deploy:`, `commands: release:` — are in
[dev.yml](dev-yml.md#targets); the internals are in
[lifecycle-architecture.md](lifecycle-architecture.md); the design record
is
[ADR-0013](DECISIONS.md#adr-0013--the-lifecycle-model-targets-derived-builds-two-ports-a-stamped-store).

## Vocabulary

A **target** is one thing the project builds, declared in `dev.yml` with
the axes it varies over (`platforms`, `configs`). A **build** is one
point of target × platform × config, named `<target>[-<platform>][-<config>]`.
dev derives the builds; nothing declares them.

`dev build` produces a build's **install**: the runnable, staged output,
whatever the toolchain calls done. `dev package` turns the install into
an **artifact**: the archive plus a `build-id.json` manifest, kept in the
**store** at `<data root>/artifacts/<project>/<build>/`. The store is
keyed by the project's `name:`, so one host serves every checkout of the
project.

A **channel** is a destination artifacts ship to, declared under
`commands: deploy:` or contributed by the lock. `dev deploy <channel>`
ships artifacts from the store on the channel's **testing** track, or
from a release on its **live** track. `dev release` cuts a tag and
attaches archives to a GitHub release; it deploys nothing.

## Naming a build

Every verb acts on one build, named three ways that mean the same thing:

- **A positional**: a full build name (`cellbound-3d-win64-release`) or a
  pattern with an axis left out (`cellbound-3d-release`,
  `cellbound-3d`). An omitted axis takes the target's first declared
  value. A target with no axes is its own build: `rspock`.
- **Flags**: `--target T [--platform P] [--config C]`. They combine with
  a positional pattern (`dev build cellbound-3d --config release`), but
  an axis named on both sides is refused, as are two positionals or a
  positional beside `--target`.
- **Nothing**: bare `dev build` and `dev package` mean the first declared
  target's default build. `dev help build` says what that is for this
  project. List the fast-loop target first.

Parsing takes the longest declared target name that prefixes the input,
then an optional platform, then an optional config. A platform or config
the target does not declare is refused, as is a trailing segment or an
unknown target.

| Input | Target `cellbound-3d` (`win64 linux64` × `dev release`) |
| --- | --- |
| `cellbound-3d-win64-release` | the build |
| `cellbound-3d-release` | default build `cellbound-3d-win64-release` |
| `cellbound-3d-linux64` | default build `cellbound-3d-linux64-dev` |
| `cellbound-3d` | default build `cellbound-3d-win64-dev` |
| `cellbound-3d-macos` | refused: the target declares no `macos` |

Tab completion offers every build and every pattern; `package` offers
only the shippable ones (every target but `packager: none`).

## `dev build`

```
dev build [BUILD] [--target T] [--platform P] [--config C] [--runner L | --container]
```

Runs the target's `build:` script at the repo root with the build in its
environment ([the build script's environment](dev-yml.md#the-build-scripts-environment))
and `DEV_INSTALL` naming `<store>/<build>/install/`, created before the
script runs. A target with no `build:` has nothing to compile: `dev build
rspock` says so and does nothing.

Where the script runs is decided by the target's `environment:`; see
[Where a verb runs](#where-a-verb-runs).

## `dev package`

```
dev package [BUILD] [--target T] [--platform P] [--config C] [--no-build] [--runner L | --container] [--fetch]
```

`package` implies `build`, make-like. For the selected build:

1. A target declaring `packager: none` is refused by name: it is built,
   never packaged.
2. The builder runs unless the target has no `build:`, `--no-build` was
   given, or the store's artifact is **current**: packaged from a clean
   tree at the commit the tree is at now. A dirty tree is never current,
   so an uncommitted change rebuilds every time.
3. The packager writes `<build>.<ext>` beside the install: `archive`
   zips the install (or writes `.tar.zst`, split into parts with a
   `MANIFEST` when asked); `as-is` adopts the one file the install holds;
   a `package:` script writes whatever it writes at `$DEV_ARTIFACT.<ext>`.
   See [Packagers](dev-yml.md#packagers).
4. `build-id.json` is stamped last, so a failure anywhere above leaves no
   manifest and the directory does not read as an artifact:

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

The **build id** is `<semver>+<sha>` from a clean tree,
`<semver>+<sha>.dirty.<utc instant>` from a dirty one, and
`<semver>+unknown.<utc instant>` outside git. The semver is the first
line of the repo's `VERSION` file when the stamp is written, `0.0.0`
when there is none.

A current artifact is still re-archived and re-stamped; only the compile
is skipped.

`--fetch` applies to a remote package: the artifact and its manifest are
brought back into this machine's store for the build, where `dev deploy`
here reads them. Without it the artifact stays in the store of the host
that packaged; see [`--fetch`](#--fetch).

## `dev deploy <channel>`

```
dev deploy <channel> [BUILD] [--config C] [--release V] [--allow-stale] [--force] [--dry-run] [--runner L]
```

`deploy` never builds. It ships what `package` left in the store, or,
with `--release V`, what `release` attached to the GitHub release, and
refuses with the fix named when that is not enough.

### What ships

1. **Candidates.** The channel's accept set (`targets:` in `dev.yml`),
   spelled out per platform: `cellbound-3d` over two platforms is two
   entries, each with its config open. A `BUILD` positional narrows the
   set to the builds it spans that the channel accepts; one spanning no
   accepted build is refused with the accept set named, unless `--force`,
   which ships every build the positional spans. `--force` needs a
   positional. One artifact ships per entry.
2. **Config.** `--config C` keeps the builds of that config; otherwise
   every accepted config is a candidate.
3. **Source.** From the store: the artifacts that exist. None is refused
   with "`dev package <build>` first"; several is refused with both
   listed and `--config` as the fix. From a release: the builds the
   release carries an archive of. None is refused — a release ships what
   `release:` cut into it; the store never substitutes — and several is
   refused with `--config` as the fix.
4. **Staleness.** A store artifact whose `build-id.json` is not from a
   clean tree at this commit is refused unless `--allow-stale`, which
   ships it and marks it in the report. A release is cut from a tag, so
   `--allow-stale` beside `--release` is refused.

### Tracks

An artifact from the store ships on the channel's **testing** track; an
archive of a release ships on its **live** track. The source decides, and
nothing in `dev.yml` or on the command line changes it. Each publisher
maps the two tracks onto its destination's own (Steam's beta and default
branches, SMR's `beta` and `release` stabilities, a staging rsync's one
track).

### From a release

With `--release V`, `release.json` is downloaded from the GitHub release
`v<V>` first; a tag with no release is refused naming the `dev release`
that would cut it. The selected archives are downloaded under their asset
names into the store's `.releases/v<V>/` and each is verified against
the SHA-256 `release.json` records (a split set's `MANIFEST` first, then
every part against it). A file already there that verifies is not
fetched again, so a release fanned out over several channels crosses the
wire once. A file that does not verify is deleted and the deploy refused
with nothing shipped.

### The protocol

The channel's publisher ships the selection in one call. A `run:` script
runs at the repo root once per archive with
[the channel script's environment](dev-yml.md#the-channel-scripts-environment);
a nonzero exit ends the deploy at that archive, named with the code, and
the archives before it shipped. A lock-contributed publisher ships its
own way ([Built-in publishers](#built-in-publishers)).

The publisher has the terminal: a script's lines and prompts (`gem
push`'s OTP) land as written. The report:

```
┏━━ Deploying staging (testing track) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ cellbound-3d-server-linux64-release (1.4.0+3f2a1c9d8e7b): cellbound-3d-server-linux64-release.zip
┃ Shipping via run: ./bin/stage
┃ …the script's output…
┃ ✓ Shipping via run: ./bin/stage
┃ ✓ Recording as GitHub Deployment
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ staging deployed! 1 archive (testing track), GitHub Deployment #41 → https://github.com/<owner>/<repo>/deployments/staging
  run: ./bin/stage
```

A release's frame reads `(live track, release v1.2.0)`; a stale artifact
shipped under `--allow-stale` says so on its line. `--dry-run` selects
and reports, ships nothing and records nothing.

Under a remote dispatch (`--runner`, or a channel `environment:` this
machine is not) the host selects from **its own** store, or downloads
the release into its own store. An artifact is never fetched across the
dispatch for a deploy.

### Every channel at once

```
dev deploy --release V [--dry-run] [--runner L]
```

With no channel, `--release V` fans out: every channel in declaration
order, each run as `dev deploy <channel> --release V` and headed by that
line, then `v1.2.0 shipped to 2 channels: steam, rubygems`. The first
channel that refuses ends the fan-out there; the earlier channels are
deployed and recorded, the error names the channel, and naming the
channels ships the rest. `--config`, `--allow-stale` and `--force`
qualify one channel's selection and are not accepted here. Bare `dev
deploy` is refused: the store ships one channel at a time.

### The deploy record

Every deploy that ships is recorded as a **GitHub Deployment** on the
project's repo:

| GitHub Deployment | dev writes |
| --- | --- |
| `environment` | the channel's name |
| `ref` | the commit the artifact was packaged from (`build-id.json`'s sha), or the release's tag under `--release`. One deployment per distinct ref among the shipments, so `--allow-stale` shipping two commits records two. An artifact packaged outside git has no ref and cannot be recorded. |
| `payload` | `{ schema: 1, track: testing \| live, builds: [{ name, build_id }] }` |
| `description` | `dev deploy <channel>: <build names>` |
| `production_environment` | `true` on the live track |
| `auto_merge`, `required_contexts` | `false`, `[]` — the record describes a deploy and never gates one |
| one status | `success` with the publisher's **receipt** as its description (cut at GitHub's 140 characters), or `failure` with the protocol's error |

The receipt is the publisher's one-line statement of what it did (`run:
./bin/stage`; `pushed to https://rubygems.org: …`). Some publishers add a
**hint** — what to do now that it landed — which the epilogue prints
after the receipt.

Recording never masks the protocol: a deploy that shipped but could not
be recorded fails *after* the shipping step with `✗ Recording as GitHub
Deployment`, so the upload is never mistaken for undone; a failed deploy
whose failure record the forge refuses says so on stderr beside the
protocol's error. The write goes through `gh api`, so the token `gh`
holds needs `deployments: write` (the `repo` scope has it; a fine-grained
token names it).

## `dev deploy status`

```
dev deploy status [--release V]
```

Reads the records back, per channel in declaration order: the latest
deployment's state, track, ref and time, the receipt, then the builds it
carried.

```
rubygems  – nothing deployed
staging   ✓ testing from 3f2a1c9d8e7b at 2026-11-05 17:02 UTC — run: ./bin/stage
          cellbound-3d-server-linux64-release (1.4.0+3f2a1c9d8e7b)
steam     ✗ testing from 9b8c7d6e5f4a at 2026-11-04 09:10 UTC — failed: deploy script `./bin/steam` for cellbound-3d-win64-release → steam exited 2
```

A deployment the forge holds without a status reads `… pending …`.
`--release 1.2.0` asks of the tag `v1.2.0` only, so the output is the
checklist of which channels carry that release and which still read `–
v1.2.0 not deployed`.

Status is the channel's, not the release's: the release records what the
cut made, the deployments what each channel received. That is why the
command lives under `deploy`, and why no channel may be named `status`.

## `dev release`

```
dev release [<version> | major | minor | patch] [--yes]
```

Cuts a release and stops: the tag and the archives on the GitHub
release, nothing deployed. Distribution is `dev deploy <channel>
--release <version>`, a week later from the same bytes if need be.

The version is the word given, or the next of the one in `VERSION`: no
word bumps the patch, `minor` and `major` the part named. A project
without a `VERSION` file, or with one that is not three numbers, is
released by the version given only.

### The plan

The verb reads the checkout and moves nothing: it never fetches or pulls,
so the release is cut from this checkout as it stands. The tree must be
clean and HEAD on a branch (any branch: a `1.x` kept for patches releases
as `main` does). A tag `v<version>` elsewhere than HEAD is a version
already cut and is refused; one already **on** HEAD means a previous run's
cut landed, and this run resumes at the push.

```
┏━━ Release: 1.1.0 → 1.2.0 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ Base: main @ 437d12253339 — 3 commits since v1.1.0 (2 ahead of origin/main, unpushed)
┃ Notes:
┃   437d122 Fix the server's shutdown
┃   …
┃ Steps:
┃   1. Bump VERSION 1.1.0 → 1.2.0
┃   2. Tag v1.2.0
┃   3. Push main + tag v1.2.0 to origin
┃   4. Package cellbound-3d-linux64-release, cellbound-3d-server-linux64 at the tag
┃   5. Create GitHub release v1.2.0 and attach 2 archives + release.json
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
? Proceed? (y/N)
```

The base line says which checkout is being released and how far it is
from `origin/<branch>` as last fetched (`never fetched` when the remote
branch is unknown). That drift is a warning to weigh, not a refusal. The
notes are the one-line log since the previous tag, or `Release v1.2.0.`
for a first release.

`--yes` skips the confirmation. At a terminal, `n` aborts with nothing
cut. With no terminal to ask at and no `--yes`, the verb refuses: a
release is never cut on an assumed yes.

### The cut

1. When the project keeps a `VERSION` file at another version, it is
   written and committed as `Bump version to 1.2.0`, together with the
   `Gemfile.lock` lines that mirror it when the project is a gem whose
   gemspec reads `VERSION`. HEAD is tagged `v1.2.0`. Resuming skips this.
2. The branch and the tag are pushed to `origin`.
3. Each release build, in declaration order, is packaged **at the tag**
   by running `dev package <build>` as itself, so each dispatches by its
   target's `environment:` and the builder has the terminal. The
   resulting artifact must be current at the tag's commit; one packaged
   elsewhere is refused. The bump commit makes every earlier artifact
   stale, which is why the cut comes first and why the build ids read
   `1.2.0+<tag sha>`.
4. The archives are attached to the GitHub release as
   `<build>-<version>.<ext>` (`cellbound-3d-win64-release-1.2.0.zip`; a
   split set's parts as `<build>-<version>.tar.zst.00`, … with a
   rewritten `<build>-<version>.MANIFEST`), with `release.json` beside
   them. The release is created once (`gh release create --verify-tag`,
   notes from the plan) and assets upload with `--clobber`.

```
✓ v1.2.0 released! (0123456789ab, from main) → https://github.com/d3mlabs/cellbound-3d/releases/tag/v1.2.0
  cellbound-3d-win64-release-1.2.0.zip (1.2.0+0123456789ab)
  cellbound-3d-server-linux64-release-1.2.0.zip (1.2.0+0123456789ab)
Nothing deployed — ship it: dev deploy <channel> --release 1.2.0
```

A run that fails after the tag is pushed leaves the release uncreated;
running it again resumes at the push, creates the release if missing,
and re-uploads what a half-done run attached.

`release.json` is what `deploy --release` reads:

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

## Channels

A channel is declared under `commands: deploy:` ([Deploy
channels](dev-yml.md#deploy-channels)) or contributed by the lock: every
integration with a publisher contributes a channel of its own name to a
project whose lock pins it. The two sets merge by name:

| Declared | Contributed | Result |
| --- | --- | --- |
| with `run:` | any | the script replaces the publisher; dev still selects, checks and records |
| without `run:` | a publisher of that name | the declaration configures it: `targets:` is the accept set, `desc` the row, the protocol the integration's |
| without `run:` | none | bound with a fault saying which fix applies: *this dev ships no `x` publisher* (`dev up` once a release ships it) or *deps.lock pins no `x`* (depend on it, `dev deps update`), or declare `run:`. The channel lists in `dev help deploy` with the cause on its Protocol line and `deploy <channel>` refuses with it; every other verb runs. |
| — | a publisher | the channel appears as the lock's: every packageable build accepted, a stock `desc`. A project with nothing packageable gets no row. |

`dev help deploy` lists each channel with its environment, its accept set
expanded to builds (`Accepts: …`) and where its protocol comes from
(`Protocol: run: ./bin/stage`, `Protocol: publisher: steam`).

## The channel contract

Two rules hold for every publisher, script or built-in, and make the verb
the same over either:

- **A publisher reads the archive and never rewrites it.** The file is
  what `build-id.json` or `release.json` says it is, before and after a
  deploy. A channel that needs another layout unpacks or stages into its
  **scratch**, `<data root>/artifacts/<project>/.<channel>/`, created
  before the publisher runs and kept between deploys (an unpacked tree
  Steam's content builder diffs against, SMR's staged upload).
- **A publisher ships what the verb selected and never selects on its
  own.** The accept set, the config choice, the source, the staleness and
  force rules are the verb's and identical for every protocol.

Credentials come from `dev cred` or the script's environment, never from
`dev.yml`.

**Options.** What a publisher cannot know from a build — the
destination's identifiers — the channel declares under its own name
(`steam:` on the `steam` channel). The publisher reads them first thing
in a deploy and refuses a missing or malformed key by name before any
archive is unpacked or tool run. Options are refused beside `run:`: the
script replaced the publisher they would configure.

**Unpacking.** A destination that takes a directory gets the archive
extracted into the scratch in every form `package` writes (zip,
`.tar.zst`, a split set through its `MANIFEST`). The extracted directory
is replaced on each deploy so nothing from a previous one rides along.

### Built-in publishers

| Channel | Contributed by | `testing` | `live` | Credentials |
| --- | --- | --- | --- | --- |
| `rubygems` | a `gem` declaration | refused: rubygems.org has no track that is not live | `gem push` of each `.gem` | `dev cred` `rubygems/api_key` (`GEM_HOST_API_KEY` overrides) |
| `ghcr` | an `image` block | pushed as `ghcr.io/<org>/<name>:testing-<build id>` | pushed as `ghcr.io/<org>/<name>:<version>` | the registry login's: gh's token with `write:packages`, or `DEV_REGISTRY_TOKEN` |
| `steam` | a `steam` app pin | set live on the `beta` branch | uploaded; the operator sets it live on `default` in Steamworks | `dev cred` `steam/username`, `steam/password` (or steamcmd's cached login) |
| `egs` | the `egs` BuildPatchTool pin | labelled `Testing` | labelled `Live` | `dev cred` `egs/client_id`, `egs/client_secret` |
| `ficsit` | a `ficsit` mod pin | SMR stability `beta` | SMR stability `release` | `dev cred` `ficsit/api_key` (`FICSIT_API_KEY`) |
| `brew` | a formula pinned from a tap | refused: a formula points at a release asset | the tap's formulae rewritten to the release's assets | the `gh` login, pushing to the tap |

A contributed channel the project does not declare accepts every
packageable build. A project with a gem target and a zip target declares
`rubygems: { targets: [<gem>] }` to keep the zip out; each publisher also
refuses an archive of the wrong kind before shipping anything.

#### rubygems

Runs `gem push --host https://rubygems.org <archive>` once per `.gem` at
the repo root, the API key handed through the environment. An archive
that is not a `.gem` is refused before the first push. A store artifact
is refused: a pushed version can never be reused, so a working artifact
has nowhere to go; the message names `dev deploy rubygems --release <v>`.
Receipt: `pushed to https://rubygems.org: <file>, …`.

#### ghcr

Each archive is a `docker save` tarball of one image tagged
`ghcr.io/<org>/<name>:<anything>`; the archive decides the repository,
the track decides the tag. Every archive is `docker load`ed first — a
tarball that is not an image, carries no tag, or is tagged under another
registry refuses the deploy with nothing pushed — then each image is
tagged and pushed inside one registry login. The testing tag spells the
build id's `+` as `-`. Receipt: `pushed <ref>, …`.

#### steam

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

Each accepted build must match exactly one `depots:` pattern. A deploy
unpacks each archive into `.steam/depots/<DepotID>/`, writes the content
builder's scripts under `.steam/scripts/` and runs `steamcmd +runscript`
on a `0600` script (login, `run_app_build`, quit), so credentials are on
no command line. `.steam/output/` keeps steamcmd's chunk cache, which the
next upload's delta is computed against.

The testing track sets the build live on the testing branch. Steam
refuses to set the `default` branch live from a script, so the live track
uploads the build and the receipt names the Steamworks page where to set
it live; `branches: { live: <beta branch> }` sets that branch live
instead. Receipt: `steam build <BuildID> of app <app> (depots …) set live
on <branch>`, or `… uploaded — set it live on the default branch in
Steamworks: <url>`.

The build account is `dev cred` `steam/username` (`STEAM_USERNAME`); its
password `steam/password` (`STEAM_PASSWORD`), or steamcmd's cached login
for that account when absent (a CI runner logs in once interactively,
Steam Guard included).

#### egs

Epic's only publishing tool is BuildPatchTool, so pinning it
(`egs "BuildPatchTool"` in `dependencies.rb`) is what contributes the
channel.

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

Each accepted build must match exactly one `artifacts:` pattern and be
win64 or macos; a linux64 build is refused before anything runs. Per
shipment the archive is unpacked into `.egs/builds/<build>/`,
`BuildPatchTool -mode=UploadBinary` runs with the build root,
`BuildVersion` the build id and a `CloudDir` of `.egs/cloud/<artifact
id>/` (kept, so the tool diffs against the previous upload), then
`-mode=LabelBinary` applies the track's label. A working artifact is
labelled `Testing` rather than left unlabelled because Epic deletes
unlabelled binaries after a week. Receipt: `egs <version> → artifact
<id>, … labelled <label>`.

The product's client is `dev cred` `egs/client_id` (`EGS_CLIENT_ID`) and
`egs/client_secret` (`EGS_CLIENT_SECRET`); the secret reaches the tool
through an environment variable, never argv. A lock pinning no `egs`
dependency, or a pinned tool not yet installed (`dev up`), is refused.

#### ficsit

The Satisfactory Mod Repository (SMR, ficsit.app). Each shipment is an
Alpakit per-target zip — the mod's `<ModRef>.uplugin` at the root and
cooked content under `Content/Paks/<target>/` — which is what a mod
target's `packager: as-is` leaves in the store. The publisher reads the
mod reference from the `.uplugin` and the target (`Windows`,
`WindowsServer`, `LinuxServer`) from the paks directory; nothing in
`dev.yml` names the mod.

The per-target zips are merged into SMR's multi-target zip, every entry
under its target's directory, under `.ficsit/merge/`. Two builds of one
target (a Steam and an Epic client) are unioned; a file both carry must
be byte-identical, else the deploy is refused naming the file and both
archives. The archives must be one mod's with a byte-identical
`.uplugin`, and the result under SMR's 1 GB.

The upload is SMR's chunked GraphQL upload in 10 MB parts, finalized with
the track's stability and a changelog naming the builds, then polled
every 10 s for up to 10 minutes while SMR processes it. SMR's own
refusals (a mod not yet approved, a missing disclosure, a `SemVersion`
the mod already has) come back in SMR's words. The version is the
`.uplugin`'s `SemVersion`: deploying a working build twice without
bumping it is refused by SMR on the second upload.

The credential is the user's API key from ficsit.app's settings page:
`dev cred get ficsit api_key`, or `FICSIT_API_KEY`. Receipt: `ficsit:
<ModRef> (<targets>) → <stability>, version <version> (<id>),
auto-approved` or `awaiting approval`.

#### brew

A project whose lock pins anything from a tap through brew gets a `deploy
brew` channel. It ships releases only: a formula points at a release
asset, so a store artifact is refused and `dev deploy brew --release
<version>` is the only form.

One formula per shipment, named as the build: `Formula/<build>.rb`. The
publisher rewrites only the formula's stable `url`/`sha256` pair — never a
`resource`'s or a bottle's — with the asset's download URL as GitHub
reports it and the digest `release.json` carries. The formula's body
(`depends_on`, `install`, `caveats`) stays hand-authored in the tap. A
formula already at that pair is left alone; when none moved, the receipt
says `<tap> already points at <tag>: <names>` and nothing is committed.
Otherwise one commit, `<names>: <version>`, is pushed to the tap's
default branch, and the receipt is `<tap>@<sha>: <names> → <tag>` with
the hint `To update locally: brew update && brew upgrade …`.

The tap is the lock's: the one tap the brew-family pins come from (two is
refused). It is cloned into the scratch (`.brew/<user>/homebrew-<repo>`)
and reset to the remote's default branch on every run.

## The dependency graph

Each verb needs what the one before it leaves, and names the missing step
rather than performing it:

| Verb | Needs | When missing |
| --- | --- | --- |
| `build` | the build's environment, able to produce its platform: here, or on a host the remote dispatch reaches | an image without the platform in `target_platforms` is reported at load and the build refuses until `dev deps update`; a host-placed build whose platform this machine is not is refused (`--runner` sends it elsewhere); an environment this machine is not goes to a runner, else to the project's container, which needs the engine up (`dev up`) |
| `package` | a current build | makes it: the builder runs when the artifact is not current; `--no-build` trusts the install |
| `deploy <channel>` | an artifact per accepted (target, platform) in the store; a channel; the channel's environment; a protocol; to record, a repo `gh` reaches with `deployments: write` | "`dev package <build>` first"; a channel exists or `deploy` does not; a channel with no protocol is refused at load with both fixes; a record the forge refuses fails after the shipped lines |
| `deploy <channel> --release V` | release `V` cut, carrying an archive of each accepted build; `contents: read` for the download | "`dev release V` cuts it" for a tag with no release; a build the release has no archive of is refused; a download whose digest is not `release.json`'s is removed and refused |
| `deploy --release V` | the above for every channel | stops at the first channel that refuses; name the channels to ship the rest |
| `deploy status` | a channel; a repo `gh` reaches | the forge's refusal is the command's error |
| `release` | a clean checkout on a branch with `origin`; the version not yet cut, or cut on HEAD (a resume); `release:` naming packageable builds; `contents: write`; a terminal or `--yes` | refuses before anything moves; packages each release build at the tag itself, so staleness cannot arise; a tag pushed with no release is what the retry resumes |

## Where a verb runs

A verb's seam — the builder, the packager, the channel's protocol — runs
where the target's or channel's `environment:` places it, under [the host
rule](containers.md#the-host-rule): natively when this machine is the
environment, otherwise on a host that is.

### Dispatch resolution

At load, every build with a platform is checked against the environment
named for it: an image must list the platform in its `target_platforms`
([Capability](dev-yml.md#capability)). `host` produces the platform this
machine is, which is checked when a verb asks, since the same `dev.yml`
loads on a Mac and a Linux box.

When a verb runs, for the selected build:

1. **Is the target bound?** When the lock could not place the builds at
   load (an image pinned before its block declared `target_platforms`,
   a lock written by another dev's template), `dev help build` lists the
   builds without an environment column and the verb refuses until `dev
   deps update` re-locks.
2. **Can this host produce the build?** A host-placed `linux64` build on
   a Mac is refused and marked `(linux64 only)` in the listing. Skipped
   under `--runner` and `--container`: that host produces it, not this
   one.
3. **Where does the seam run?**

| Placement | This machine | Runs |
| --- | --- | --- |
| any | `--runner` and `--container` both given | refused: one host per verb |
| any | `--runner <label>` | **remote** to that label, whatever the placement |
| `host` | `--container` | refused: a host-placed build has no image to run in |
| `host` | any | **native** |
| image *I* | `--container` | **remote** to the project's container of *I*, even on a host that could build natively |
| image *I* | provisioned from *I* (the box, a hosted runner), or inside *I*'s container | **native** |
| image *I* | neither; `lifecycle.runner` set | **remote** to that label |
| image *I* | neither; the repo's enrolled runner online | **remote** to the enrolled runner |
| image *I* | neither; nothing standing | **remote** to the project's **container** of *I*. The container is brought up by `dev up`; a verb that reaches for it while the engine is down is refused before anything is pushed. |
| any | inside an Actions job, and the row above is remote | refused: a job never dispatches a job |

**The enrolled runner** is what bare `dev runner register` makes: a runner
at the repo's scope carrying the repo's name as label. It is available
when the Actions API lists one online; busy counts, offline does not, and
GitHub being unreachable is an error rather than "no runner". See
[Runners](runners.md#the-enrolled-runner).

`dev help build` shows the resolution as an environment column: `host`;
`cellbound-3d-linux` when this machine runs it natively;
`cellbound-3d-linux (remote)` when the verb would leave. Which host is
decided when the verb runs; help never asks the forge.

### The remote dispatch

A verb that leaves the machine:

1. pushes the working tree as a snapshot branch ([the sync
   step](#the-sync-step));
2. prints one dim line — `→ on <runner>, snapshot <sha>`, or `→ in
   <image> (container), snapshot <sha>` — so the next output is known to
   be another host's;
3. runs the verb there and returns with its verdict;
4. deletes the branch.

**On a runner**, dev dispatches its generic workflow on the snapshot
branch. The project copies it verbatim from `share/workflows/dev-lifecycle.yml`
to `.github/workflows/dev-lifecycle.yml` and commits it; a dispatch that
finds it missing refuses before anything is pushed and names the `cp`.
Only `workflow_dispatch` triggers it, so a snapshot push alone runs
nothing. Its inputs:

| Input | Carries |
| --- | --- |
| `verbs` | one or several dev invocations, comma-separated, as typed after `dev` (`package cellbound-3d-win64-dev --no-build`) |
| `runner` | the label the job demands beside `self-hosted` |
| `fetch` | whether to upload the packaged artifact as a workflow artifact named after the build |

The job checks out the snapshot branch, puts dev on PATH, runs `dev up`,
then the verbs. The run is located by its branch (unique to the dispatch),
polled for up to a minute while GitHub registers it, and `gh run watch`
streams it to the terminal; the dispatch prints the run's page first. A
run that does not complete successfully is the verb's failure, naming the
verb, the label, GitHub's conclusion and the page.

**In the container**, the verb runs by `docker exec` into the project's
persisted container (a one-shot `docker run --rm` for a non-persisted
image). The container fetches the snapshot into a workspace of its own
under its data root, `/var/lib/dev/workspaces/<checkout>-<id>`, kept
between dispatches so ignored build state (`Intermediate/`, `Binaries/`,
the DDC) stays warm, resets to the snapshot and runs `dev <verb>` there.
Nothing of the host's checkout is mounted. The container's exit status is
the verdict, and its output is the terminal's directly. `dev up` fills
the same workspace, so the first verb finds it warm.

**The invocation** the host runs is the one typed, with the build fully
qualified (never a default the host would resolve differently), the
seam's flags kept (`--no-build`; `deploy`'s `--config`, `--allow-stale`,
`--force`, `--dry-run`) and the dispatch's consumed (`--runner`,
`--container`, `--fetch`).

**`--runner <label>`** forces the remote dispatch to that label whatever
the placement: a pool the org enrolled, another repo's runner, the repo's
own. **`--container`** forces the project's container the same way, to
check the image from a host that could build natively. **`lifecycle.runner`**
(`dev config set lifecycle.runner <label>`, or `DEV_LIFECYCLE_RUNNER`) is
the standing form, read before the enrolled runner. None of the three is
consulted while the verb can run natively.

#### `--fetch`

By default the artifact stays in the store of the host that packaged it,
and that host deploys from its own store. `package --fetch` brings the
archive and `build-id.json` back into this machine's store directory for
the build: from a runner, as the workflow artifact the job uploaded; from
the container on a Mac, by `docker cp`. On a Linux host the container's
data root is the host's, so the artifact is already there.

**A verb inside an Actions job never dispatches again.** A runner that
finds itself not to be the build's environment is misprovisioned, and
the verb says so rather than dispatching onto itself or between two
runners forever.

### The sync step

What a remote host builds is the operator's working tree, uncommitted
changes included. The one transport every host has to it is the
project's GitHub remote. Before a dispatch:

1. **Refuse while nothing has left the machine** if a project workflow
   would run on the push. An `on: push` with no `branches`,
   `branches-ignore` or `tags` filter fires for every branch; the refusal
   names every such workflow and both fixes: `on: push: branches: [main]`,
   or `branches-ignore: ['dev/build/**']`. Without this, every remote
   `dev package` would also be a CI run on a tree nobody committed.
2. **Commit the working tree through a temporary index.** HEAD, the
   branch and your own index never move. A clean tree snapshots to HEAD
   itself, so the artifact the host stamps names the commit you are at.
   The commit works on a host with no `user.*` configured.
3. **Push** the commit to `dev/build/<runner>/<utc instant>-<nonce>` on
   `origin` (`dev/build/cellbound-3d/20261105T173000Z-a1b2c3`), with
   `--force` and `--no-verify`: the namespace is dev's, and a pre-push
   hook guards the project's branches, not a throwaway one.
4. **Run the dispatch**, then **delete the branch**, however the dispatch
   ended. The delete is best-effort: a dispatch that succeeded is not
   failed by a lost connection afterwards.

A branch that outlives its dispatch (a killed dev, a lost connection, a
read-only credential) is pruned by `dev cache gc` once older than seven
days, read from its name ([Data root](data-root.md#dev-cache-gc)).

A snapshot-branch build is unreviewed code running on the host as its
job user: the same trust a self-hosted runner already extends to the
repo's own branches.
