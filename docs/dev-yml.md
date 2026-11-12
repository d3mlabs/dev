# dev.yml reference

`dev.yml` sits at the git root and declares the project's name, its
commands, and — for projects that ship something — its build targets,
deploy channels and release contents.

```yaml
name: myproject

engine:                 # optional: minimum container engine size
  cpus: 8
  memory_gib: 24

commands:
  up:
    desc: Setup dev environment
    run: ./bin/setup.rb
    environment: host
  build:
    desc: Build the project
    run: ./bin/build.sh
    environment: myproject-linux
  test:
    desc: Run tests
    run: ./bin/test.sh
  console:
    desc: Start Ruby console
    run: ./bin/console
    repl: true
  db:
    desc: Database chores
    commands:
      reset:
        desc: Reset the dev database
        run: ./bin/db_reset.sh
```

## Top-level keys

| Key | Meaning |
|---|---|
| `name` | Display name, and the key dev stores the project's artifacts under. |
| `engine` | Optional. `cpus`, `memory_gib`, `disk_gib`: the smallest container engine this project's builds were tuned for. dev sizes the engine up to it and refuses to run a containerized command on a smaller one. See [Containers](containers.md#engine-resources). |
| `commands` | Map of command name to spec. |
| `targets` | Optional. What the project builds. Declaring any makes `dev build` and `dev package` exist. |

## Commands

A command spec has `run`, `commands`, or both.

| Key | Meaning |
|---|---|
| `desc` | One line, shown in listings. |
| `run` | Shell command, run from the repo root. Extra arguments to `dev <cmd>` are appended verbatim, flags included. |
| `commands` | Nested specs, any depth. With `run` beside it, bare `dev <cmd>` runs `run` and a first argument that is not a child's name is forwarded to it. Without `run`, bare `dev <cmd>` prints usage. A child cannot be named `help`. |
| `repl` | `true` for consoles and other interactive sessions: the command is exec'd directly, with no `✓ Done` footer. A command with subcommands cannot be a repl. |
| `environment` | Where the command runs: an `image` name from `dependencies.rb`, or `host`. See [Where commands run](#where-commands-run). |
| `hidden` | `true` keeps the command callable but out of listings. For plumbing other commands call. |

### Where commands run

A project whose lock pins an `image` block runs commands in a container of
that image unless told otherwise. `environment:` names the image, or `host`
for this machine via `shadowenv exec` (provisioning, deploying, the editor).

When `environment:` is omitted: the project's one image if the lock pins
exactly one; the host if it pins none; refused, with both names listed, if
it pins several. `host` is a reserved name; an image cannot be called that.

Every `environment:` is checked against the lock when `dev.yml` loads, so a
typo fails at `dev help`, not on first run. `dev help` shows each command's
resolved environment as a trailing column — `host`, `myproject-linux`, or
`myproject-linux (container)` when running from here crosses into one.

A host that was itself provisioned from the image runs its commands
natively; see [the host rule](containers.md#the-host-rule).

### Commands on a builtin's name

A project spec on a builtin's name merges with it. `run:` runs after the
builtin's body (the usual case is `up:`). Subcommands merge child by child:
new children are added, same-named children replace the builtin's. `up:`
with only `commands:` keeps bare `dev up` as the builtin and adds the
children.

## Targets

A **target** is one thing the project builds: a client, a dedicated server,
a library, a gem. Each target varies over two optional axes, `platforms`
and `configs`, and dev derives one **build** per combination.

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
  snappy-steam:
    desc: Client mod against the Steam game
    platforms: [win64]
    build: ./bin/build.sh
    packager: as-is
  ue-toolchain:
    desc: The engine toolchain tarball
    build: ./publisher/build.sh
    packager: { archive: { split: 2GiB } }
  rspock:
    desc: The gem
```

| Key | Meaning |
|---|---|
| `desc` | One line. |
| `platforms` | Subset of `win64`, `linux64`, `macos`. First is the default. |
| `configs` | Subset of `debug`, `dev`, `release`. First is the default. |
| `environment` | One value for every build, or one per platform (`{ linux64: img, macos: host }`, naming exactly the target's platforms). Same values as a command's. Omitted: the project's default, as for a command. |
| `build` | Shell command that produces the **install** — the runnable, staged output — into `$DEV_INSTALL`. Omitted: nothing to compile; `package` runs alone. |
| `package` | Shell command that turns the install into the **archive** at `$DEV_ARTIFACT` plus the extension it writes. Exclusive with `packager`. |
| `packager` | A built-in packager. Default `archive`. See below. |

### Build names

Builds are named `<target>[-<platform>][-<config>]`, with a segment present
exactly when the target declares that axis: `cellbound-3d-win64-release`,
`cellbound-3d-editor-macos`, `rspock`. A partially qualified name is a
pattern: an omitted segment means the axis's default when running a verb,
or "any" where a set is accepted.

Validation at load: a target name is lower-case alphanumeric segments
joined by single dashes and may not end in a platform or config id. With
targets declared, `commands: build:` and `commands: package:` are refused
(the verbs are derived), and no command may be named like a build.

### Capability

An image declares what it can build with `target_platforms` in its `image`
block (see [Dependencies](dependencies.md#image)). Each platform build is
checked at load against the environment it is placed on: an image that
does not list the platform is refused with the fix named. An image that
declares no `target_platforms` can build nothing with a platform.

`host` builds the platform this machine is. That check happens when a verb
asks for the build, because the same `dev.yml` loads on every machine.

### Packagers

| `packager` | Result |
|---|---|
| `archive` (default) | `<build>.zip` of the install's contents, symlinks kept. `{ archive: { format: tar } }` writes `<build>.tar.zst`; `{ archive: { split: 2GiB } }` cuts it into `.00`, `.01`, … parts under that size plus a `<build>.MANIFEST` of SHA-256s. The tar form needs `zstd` on PATH. |
| `as-is` | The install already is the archive (Alpakit's zip, `gem build`'s `.gem`): its one file is adopted as `<build>.<ext>`. |
| `none` | Built, never shipped. Invisible to `package`, `release` and `deploy`. |

For a `package:` script with a twist on the default, the hidden `dev pack
DIR [--out STEM] [--format zip|tar] [--split SIZE]` archives any directory
and prints the files it wrote.

### The build script's environment

`build:` and `package:` scripts read their parameters from the environment,
never from flags:

| Variable | Set when |
|---|---|
| `DEV_TARGET` | always |
| `DEV_PLATFORM`, `DEV_CONFIG` | the target declares that axis |
| `DEV_INSTALL` | always; the install directory, created before the script runs |
| `DEV_ARTIFACT` | `package:` only; the archive path **without** its extension |

Map dev's ids to the toolchain's switches in the script (`dev → Development`,
`win64 → Win64`), and fail loudly on a name it does not handle
(`*) exit 2`). An axis the target does not declare is unset, so `set -u`
catches a `case` over it.

## Deploy channels

A **channel** is a destination artifacts ship to. Channels are children of
`commands: deploy:`; each becomes `dev deploy <channel>` with its own help
and completion. `deploy` itself has no `run:` and must have children.

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
        steam:
          app: 480
          depots:
            cellbound-3d-steamworks-win64: 481
            cellbound-3d-server-linux64: 482
      ficsit:
        targets: [snappy-steam]
```

| Key | Meaning |
|---|---|
| `desc` | One line. |
| `targets` | Required. The **accept set**: builds or patterns the channel ships. Bare `dev deploy <channel>` ships one artifact per accepted target and platform; a `BUILD` argument narrows it; a build outside the set needs `--force`. |
| `run` | The channel's protocol as a script, run once per archive from the repo root. Omitted: the lock's publisher of the channel's name. |
| `environment` | Where `run:` executes. Same values as a command's. Needs `run:`. |
| `<channel>:` | The lock publisher's options, under the channel's own name (`steam:` on the `steam` channel). Refused beside `run:`. What each publisher reads: [the channel contract](lifecycle.md#the-channel-contract). |

A channel cannot be named `help`, `status` or `releases`, and cannot have
`commands:`.

### Channels from the lock

Integrations with a publisher contribute a channel of their own name:
`steam` for a project pinning the Steamworks SDK, `rubygems` for one
declaring gems, `ghcr` for one pinning an image, `ficsit` for an SML mod,
`brew` for a project whose lock's tap publishes it. A declared channel of
the same name **with** `run:` replaces the publisher; one **without**
`run:` configures it (`targets:` and options); a contributed channel the
project does not declare appears as is, accepting every packageable build.
A declared channel with neither `run:` nor a matching publisher is refused
at load.

### The channel script's environment

| Variable | Meaning |
|---|---|
| `DEV_TARGET`, `DEV_PLATFORM`, `DEV_CONFIG` | the artifact's build, as for `build:` |
| `DEV_ARTIFACT` | the archive **file** (with extension) |
| `DEV_CHANNEL` | the channel's name |
| `DEV_TRACK` | `testing` (from the store) or `live` (from a release) |
| `DEV_SCRATCH` | the channel's scratch directory, kept between deploys |
| `DEV_BUILD`, `DEV_BUILD_ID`, `DEV_ARCHIVE_SHA256`, `DEV_SHA` | from the artifact's manifest; `DEV_SHA` is `unknown` outside git |
| `DEV_DIRTY`, `DEV_PACKAGED_AT` | store artifacts only |
| `DEV_RELEASE_VERSION` | release archives only |

The archive is read-only to the script; unpack or stage into `DEV_SCRATCH`.
A nonzero exit ends the deploy at that archive; earlier ones shipped.
Credentials come from `dev cred` or the script's own environment, never
from `dev.yml`.

## Release

`commands: release:` says what a release contains. Declaring it makes `dev
release <version>` exist. It takes `desc` and `targets` only; `run:` and
`commands:` are refused.

```yaml
commands:
  release:
    desc: Cut a release
    targets: [cellbound-3d-release, cellbound-3d-server-linux64-release]
```

`targets` lists builds with the config named: `cellbound-3d-release` means
both platforms at release config; `cellbound-3d-win64` spans two configs
and is refused with the fully qualified names to pick. A `packager: none`
target cannot be listed. Omitted (`release: {}`), the release is every build
of every packageable target, allowed when each such target has at most one
config.

What the verbs then do — `build`, `package`, `deploy`, `release`, where
each runs and what it leaves behind — is in [Lifecycle](lifecycle.md).
