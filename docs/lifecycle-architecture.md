# Lifecycle architecture

How `lib/dev/lifecycle` turns a `dev.yml` into the verbs `build`,
`package`, `deploy` and `release`: the classes, the ports between dev
and a toolchain, how a verb's output reaches the terminal, and what to
build when adding a builder, packager or publisher. The operator's view
is [lifecycle.md](lifecycle.md); the design record is
[ADR-0013](DECISIONS.md#adr-0013--the-lifecycle-model-targets-derived-builds-two-ports-a-stamped-store).

## Ontology

One class per noun, none playing two roles.

| Concept | Class | What it is |
| --- | --- | --- |
| Target | `Lifecycle::Target` | What can be built, with the axes it varies over (`platforms`, `configs`), a builder spec, a packager spec and an environment. Declared in `dev.yml`. |
| Build | `Lifecycle::Build` | One point of target × platform × config, fully qualified, with one name. Derived, never declared. |
| Build pattern | `Lifecycle::BuildPattern` | A build name with an axis left out; names a set and has one default build. What a verb's positional parses to. |
| Artifact | `Lifecycle::Artifact` | What `package` makes of one build: the archive beside its `build-id.json`, in the store. A directory without the manifest is not one. |
| Manifest | `Lifecycle::Manifest` | `build-id.json`: the stamp, the build, the sha and dirtiness, the build id, the archive's name and digest. |
| Build id | `Lifecycle::BuildId` | `<semver>+<sha>`, with `.dirty.<instant>` or `unknown.<instant>` when the tree or git cannot vouch for it. |
| Store | `Lifecycle::Store` | `<data root>/artifacts/<project>/<build>/`, one directory per declared build, keyed by the project's `name:`. Reserves `.<channel>/` as a publisher's scratch and `.releases/<tag>/` for `deploy --release`'s verified downloads. |
| Channel | `Lifecycle::Channel` | Where shipments go: a name, the build patterns it accepts and a publisher spec. Declared under `commands: deploy:`, or contributed by the lock under an integration's name. |
| Shipment | `Lifecycle::Shipment` | One archive as `deploy` hands it to a publisher: file, build, build id, digest and its **provenance** (`Lifecycle::Provenance`, sealed): `Store` (the tree it was packaged from) or `Release` (the tag and the commit `release.json` records). The provenance decides the track and what a script is told; how a publisher ships the bytes does not depend on it. |
| Track | `Lifecycle::Track` | `testing` or `live`. Decided by the provenance, never the operator. |
| Publisher | `Lifecycle::Publisher` | The channel's protocol: ships the selected shipments on a track with a scratch and answers with a receipt. `ScriptPublisher` is the `run:` form; an integration publisher is set on its registry entry. |
| Receipt | `Lifecycle::Receipt` | The publisher's one-line statement of what it did, and an optional hint. What the deployment's status carries. |
| Deployment record | `Lifecycle::DeploymentRecord` | What dev says about one deploy: channel, ref, track, builds with ids, outcome, receipt. One per distinct commit among the shipped artifacts. |
| Deployment ledger | `Lifecycle::GithubDeployments` | The records as GitHub Deployments, written and read through `gh api`. `Lifecycle::Deployment` is one as the forge holds it (id, time, page); `Lifecycle::DeploymentState` is its status. |
| Release tag | `Lifecycle::ReleaseTag` | `v<version>`: what `release` cuts, what a release's deployments are recorded against, what `deploy status --release` reads. |
| Release builds | `Lifecycle::ReleaseBuilds` | What a release contains: the fully-qualified packageable builds `release.targets` names, or every build of every packageable target under `release: {}`. Owns the list's rules. |
| Release cut | `Lifecycle::ReleaseCut` | The git half of `release`: a clean tree on a branch, the `VERSION` bump with the `Gemfile.lock` lines mirroring it (`Lifecycle::ProjectVersion.files`), the tag, the push. Read into a `Plan` first; resumable when HEAD is already tagged. |
| Release assets | `Lifecycle::ReleaseAssets` | An artifact's archive under its release name, `<build>-<version>.<ext>` (a split set's parts and a rewritten `MANIFEST`), with the entry `release.json` records for it. |
| Part list | `Lifecycle::PartList` | A split archive's `MANIFEST`: `<sha256>  <part>` per line, the shape `sha256sum -c` reads. Written by the archive, renamed by the release assets, read back by the release download. |
| Release archive | `Lifecycle::GithubReleases` | The release on the forge: created once, assets uploaded with `--clobber`, downloaded back by name. Through `gh`. |
| Release archives | `Lifecycle::ReleaseArchives` | A cut release read back for `deploy --release`: `release.json` downloaded fresh, the selected archives downloaded into `.releases/<tag>/` and verified against its digests; a verified file is not fetched again, a failing one is removed and refused. |
| Snapshot | `Lifecycle::Snapshot` | The working tree as a remote host reaches it: a commit through a temporary index (`Lifecycle::SnapshotCommit`) on a `Lifecycle::SnapshotBranch` (`dev/build/<runner>/<id>`) at `origin`, for as long as the dispatch needs it. `Lifecycle::SnapshotSync` runs the step; `Lifecycle::SnapshotBranches` prunes the leftovers; `Lifecycle::WorkflowTriggers` reads the project's workflows for the `on: push` refusal. |
| Verb invocation | `Lifecycle::VerbInvocation` | A verb as a remote host runs it: the words after `dev` with the build fully qualified and the dispatch flags consumed, plus what to bring back (`Lifecycle::ArtifactFetch`: the workflow artifact's name and the store directory it lands in). |
| Workflow run | `Lifecycle::WorkflowRun` | One run of the generic workflow as the forge lists it: id, page, status, conclusion. `Lifecycle::WorkflowRuns` is its client over `gh` (dispatch, locate, watch, view, download); `Lifecycle::LifecycleWorkflow` is the contract of the workflow file: name, inputs, dev's shipped copy. |
| Step outputs | `Lifecycle::StepOutputs` | What `package` tells the Actions job it runs in (`GITHUB_OUTPUT`): the artifact's name and files, so the workflow uploads what `--fetch` downloads. Inert outside a job. |
| Shell, Git, Gh | `Lifecycle::Shell`, `Lifecycle::Git`, `Lifecycle::GitState` and `Lifecycle::Gh` | The process boundaries: spawning scripts with inherited stdio (`Shell#run`, `#pipeline`), reading the checkout, and `gh` in its captured (`Gh#capture`) and streamed (`Gh#stream`) forms. |

## Ports

Three ports separate dev from the toolchain and the destination. The
**builder** makes the install. The **packager** turns the install into
the archive. The **publisher** ships the archives `deploy` selected. The
builder never knows the archive format; the packager never knows the
toolchain; the publisher never selects and never rewrites an archive.

| Port | Interface | Implementations | Declared as |
| --- | --- | --- | --- |
| Builder | `Lifecycle::Builder#build(build, install)`, `#name`, `#version` | `ScriptBuilder` (`name` = `script`, no version) | `build: <command>` |
| Packager | `Lifecycle::Packager#package(build, install, archive_stem) → PackedArchive` | `Archive` (zip or tar.zst, optionally split), `AsIsPackager`, `ScriptPackager`, `NonePackager` | `packager:` / `package:` |
| Publisher | `Lifecycle::Publisher#publish(shipments, channel:, track:, scratch:) → Receipt` | `ScriptPublisher`; the lock's integration publishers | a channel's `run: <command>`; a registry entry's `publisher:` |

`Lifecycle::Ports` maps a target's specs and a channel's to port
instances. It is the one place that matches the sealed `BuilderSpec`,
`PackagerSpec` and `PublisherSpec` variants to classes, and it holds the
publishers the lock contributed, by channel name, so a
`PublisherSpec::Integration` resolves to its instance. The manifest's
`builder` and `builder_version` fields are the builder port's `name` and
`version`, so an integration builder's engine tag lands in
`build-id.json` without the verb changing.

A script form reads its parameters from the environment, never from
flags; `Lifecycle::ScriptEnv` builds that environment. The variables and
when each is set are in
[dev.yml](dev-yml.md#the-build-scripts-environment) and
[the channel script's environment](dev-yml.md#the-channel-scripts-environment).

`Lifecycle::Unpacker` extracts an archive into a scratch in every form
`package` writes (zip, `.tar.zst`, a split set through its `MANIFEST`),
for publishers whose destination takes a directory.

## Binding a channel

`ChannelBinder` binds every channel's publisher reference against the
lock before the command tree exists. A declared channel with `run:` gets
a `ScriptPublisher`. One without `run:` whose name the lock's publishers
include gets a `PublisherSpec::Integration`. One without `run:` and
without a publisher is bound with a **fault** naming the fix, so the
channel still lists in `dev help deploy` and only `deploy <channel>`
refuses. A contributed publisher the project did not declare becomes a
channel accepting every packageable build. Reaching
`Ports::UnknownPublisherError` after binding is a wiring bug in dev, not
a `dev.yml` error.

An integration's publisher is declared on its `Deps::Registry::Entry`:
`publisher:` names the class, `publisher_needs:` the constructor kwargs
taken from the composition context (`project_root`), and `channel:` the
channel's name when it differs from the integration's (`rubygems` for
`gem`, `ghcr` for `image`, `brew` for `taps`). The registry's consistency
test fails on a `*_publisher.rb` no entry wires and on two entries
claiming one channel.

## The verbs' output

A lifecycle verb speaks `Dev::Ui`: a timed **frame** around a stage, a
**spin** for an action under a spinner, a **step** for an action that
owns the terminal, a **confirm** before anything irreversible, **note**
for a formatted line.

The split between spin and step is the stdio contract. A spinner
captures every Ruby-level write and masks stdin while it animates, so
only in-process work or a captured subprocess (`Open3.capture3`, stdin
supplied) may run under one. A child that inherits the terminal — a
`build:` script, a publisher, anything that may prompt — runs under a
step: nothing captured, its lines and prompts landing as written. The
rule is enforced: a spin owns the thread's terminal (`TerminalOwner`),
and `Lifecycle::Shell#run`, `#pipeline` and `Lifecycle::Gh#stream` claim
the terminal first and refuse under a spin
(`TerminalOwner::UnderSpinnerError`, naming the command and the fix). So
do a prompt, a frame, a step or another spin under a spin. The plain tier
enforces it too, which is where tests catch it.

A frame prefixes dev's own lines with its bar through CLI::UI's
Ruby-level `$stdout` router. A child's lines are never prefixed, in any
tier: a step's builder output sits between the step's name and its `✓`
exactly as the builder wrote it. The first frame turns the router on and
it stays on for the process; with no frame open it prefixes nothing.

Two tiers implement the vocabulary. `bin/dev` picks `Dev::Cli::UiImpl`
(CLI::UI) when stdout is a TTY or `CI` or `CLICOLOR_FORCE` is set, and
`Dev::NoUi` otherwise (a pipe, ai-flow, a runner). `NoUi` prints the same
facts as plain lines with no escape codes: the frame's title, `✓ name`
or `✗ name` per spin, a step's name before and its glyph after.
`NoUi#confirm` answers `nil`, which a caller treats as no, so `--yes` or
`--force` is how a script consents. The plain tier is the contract: a
failed action's reason is in the error that bubbles, not in a rendering.
`deploy` and `release` run inside frames; `build` and `package` run bare.

The forcing variables are the terminal's, never a reader's. `gh`
honours `CLICOLOR_FORCE` on a pipe too and would colourise the JSON dev
reads, so `Lifecycle::Gh#capture` spawns gh with colour off
(`CLICOLOR_FORCE` and `GH_FORCE_TTY` unset, `NO_COLOR=1`) while
`Gh#stream` leaves the operator's preference alone.

## Dispatch

`Dev::Cli::DispatchResolver` owns the flags `--runner` and `--container`
and the decision table in
[Dispatch resolution](lifecycle.md#dispatch-resolution). Every verb's
`before` hands its dispatch a `VerbInvocation` beside the env; the
transport then runs natively, through the generic workflow
(`WorkflowRuns`) or by `docker exec` into the project's container. The
remote forms are wrapped in `SnapshotSync`, which pushes the branch,
yields, and deletes it however the block ended. The fan-out
`deploy --release V` (`DeployAllCommand`) takes the same dispatch flags
and runs each channel's deploy as a child invocation.

## Adding a port implementation

A new builder implements `Lifecycle::Builder` (`build`, `name`,
`version`); a new packager `Lifecycle::Packager` (`package`); a new
publisher `Lifecycle::Publisher` (`publish`). A builder or packager is
wired in `Lifecycle::Ports` from a new `BuilderSpec` or `PackagerSpec`
variant, and nowhere else. An integration's publisher needs no new spec:
set it as `publisher:` on the integration's registry entry and every
project whose lock reaches the entry gets the channel. The verbs, the
selectors, the dispatcher and the store do not change: they see ports,
builds and channels, never scripts, formats or endpoints.

A publisher obeys [the channel contract](lifecycle.md#the-channel-contract):
read the shipments' archives, never rewrite them; work in the scratch
`deploy` hands it; read its options under the channel's own key and
refuse a missing or malformed one by name before touching an archive;
refuse an archive of the wrong kind before shipping anything; answer
with a `Receipt` whose first line fits a GitHub deployment status.
