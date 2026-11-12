# Containers

A project whose `dependencies.rb` pins an `image` block runs its commands
inside a container of that image. dev provisions the engine, builds or
pulls the image, keeps one container per checkout, and installs the lock
inside it.

## Which machines need a container

A command placed on an image runs **natively** on a host that was
provisioned from that image, and **in a container** everywhere else. This
is [the host rule](#the-host-rule). A Mac always runs in a container; a
Linux box runs in one unless it was imaged from the project's image; a
cloud worker baked from the image runs natively.

## The engine

One engine per host OS, provisioned by `dev up`:

| Host | Engine | What `dev up` does |
|---|---|---|
| macOS | **colima**, a per-user VM with Rosetta so amd64 images run on Apple silicon | Registers brew's `docker-buildx` with the `docker` CLI; creates or grows the VM to the repo's `engine:` hint (defaults 4 CPUs, 8 GiB). |
| Linux | **dockerd** as a system service | Installs `docker-ce` and `docker-buildx-plugin` from Docker's apt repo, enables the service, adds you to the `docker` group. One sudo prompt, only when something is missing. |
| WSL2 | dockerd inside the distro | The Linux row, plus `systemd=true` in `/etc/wsl.conf` and VM sizing through `%USERPROFILE%\.wslconfig`. Refuses while Docker Desktop's WSL integration owns `docker` in the distro. |

An explicit `DOCKER_HOST` in the environment wins and is left alone. The
`container_engine: docker` setting opts out to bare docker with whatever
daemon the CLI's context reaches — where a Docker Desktop user lands:
unsupported, not blocked.

### Engine resources

The repo's `engine:` block (`cpus`, `memory_gib`, `disk_gib`) is the
minimum its builds were tuned for. dev sizes the engine up to it and
checks the running engine against it before every containerized command.
A shortfall is an error naming the fix; the `engine_resources: warn`
setting turns it into a warning.

Sizing is a ratchet shared by every project you work on: the VM grows to
the largest hint and shrinks only when stopped.

colima:

| VM at `dev up` | Result |
|---|---|
| absent | created at the hint |
| stopped | started at exactly the hint — this is where a VM shrinks back |
| running, at or above the hint | nothing |
| running, undersized, no containers running | restarted at max(current, hint) |
| running, undersized, containers running | refused, naming the containers; `dev container down` there or `dev engine down`, then retry |

Disk only grows. `colima delete` discards the container's data root; the
next `dev up` refills it.

WSL2 writes `processors` and `memory` under `[wsl2]` in `.wslconfig` by the
same table, plus `autoMemoryReclaim=gradual` under `[experimental]`, and
leaves every other line untouched. dev runs inside the VM it is sizing, so
the restart is yours: `wsl --shutdown` from Windows, then `dev up` again.
A hint above the Windows machine's hardware is refused. A WSL session
without interop (a systemd service, an ssh login) cannot write the file;
dev warns and leaves it to a login shell's `dev up`.

### `dev engine up | down | status`

Work anywhere. `up` is the sizing step alone. `status` reports the engine's
kind and state, its size, the converge facts (on WSL2 whether a restart is
pending), every running container with dev's own named by checkout, and
the Linuxbrew prefix volumes with their owners. `down` stops dev's
containers from every checkout without asking, lists any others and asks
(`--force` answers yes), then powers the engine off — the VM on macOS,
dockerd on Linux and WSL2. It refuses an engine dev did not provision.

### Migrating off Docker Desktop

macOS: quit Docker Desktop and stop it launching at login; `brew upgrade
d3mlabs/d3mlabs/dev` brings colima, docker and docker-buildx; `dev up` in
a containerized repo starts the VM. Images are re-pulled once. Before
uninstalling Desktop, remove `"credsStore": "desktop"` from
`~/.docker/config.json` (or switch to `osxkeychain` via `brew install
docker-credential-helper`); that helper ships inside Docker.app. Bind
mounts must live under a colima-mounted path (`~` is; `/tmp` is not).

WSL2: untick the distro under Docker Desktop > Settings > Resources > WSL
integration, open a new shell, `brew upgrade d3mlabs/d3mlabs/dev`, `dev up`
(one sudo prompt installs docker-ce), `wsl --shutdown` if asked. Restart
runner services (`sudo systemctl restart 'actions.runner.*'`) so they pick
up the `docker` group, then `dev runner register` in each repo.

## The image

```ruby
image "snappy-linux", from: "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3" do
  platform "linux/amd64"
  apt "winbind", "dos2unix"
  target_platforms :win64, :linux64
  persist true
  volume "~/.dev/engines/ue:/ue"
  run_env "WWISE_TOKEN" => "wwise/token"
end
```

`from:` is a base image the org publishes, resolved to its digest at `dev
deps update` through the registry's HTTP API with your `gh` token. dev
generates the Dockerfile: the floor by digest, one apt layer, Linuxbrew on
`PATH`, a `builder` user, and a marker file `/etc/dev/environment` naming
the image and its digest. The image's tag is the Dockerfile's SHA-256
(`<registry>/<name>:<digest>`; the registry defaults to the floor's).

Nothing from the lock enters the image. The container's own `dev deps
install` installs dependencies inside, so the image rebuilds when the OS
layer changes and never when a dependency does.

### Resolving and publishing

`dev up` and `dev container up` resolve each pinned image cheapest first:
a matching local image, then a pull, then a build from the generated
Dockerfile. `DEV_PUBLISH_IMAGE=1` on `dev up` (CI sets it) pushes a built
or local image when the registry lacks the tag. A published tag is never
replaced.

The registry credential is your `gh` login: dev runs `docker login` with
`gh auth token` around the pull or push and `docker logout` after. A
classic token needs `read:packages` to pull and `write:packages` to
publish; dev names the `gh auth refresh -s …` when a scope is missing. When
the registry refuses the identity `gh` holds (GHCR refuses GitHub App
tokens), set `DEV_REGISTRY_TOKEN`; a workflow's `GITHUB_TOKEN` with
`packages: write` works. dev's logout also removes a `docker login` you
made by hand to that registry.

### What the block declares beyond the image

- `target_platforms` — the build platforms this environment's toolchain
  emits (`:win64`, `:linux64`, `:macos`). Each target's `environment:` is
  checked against it at load; see [dev.yml](dev-yml.md#capability).
- `persist true` — keep one long-lived container per checkout, so the
  build tool's incremental state survives between commands. Without it
  each command is a `docker run --rm`.
- `volume "host:container"` — extra mounts.
- `run_env "VAR" => "namespace/key"` — credentials resolved from `dev cred`
  and injected as `-e` on every run. A missing one never blocks a command.

The host's `gh auth token` rides along as `GH_TOKEN` on every exec, so a
command that calls `gh` inside has the host's auth.

### Several images

A project may pin several images. Each command and target names the one it
runs in with `environment:` ([dev.yml](dev-yml.md#where-commands-run)).
`dev up` brings each image up; `dev container status` prints a block per
image; the host rule is asked per image.

## Container lifecycle

`dev engine` is the per-user daemon every project shares. `dev container`
is this checkout's images and containers, and exists only when the lock
pins an image.

| Verb | What it does |
|---|---|
| `dev up` | Installs the lock on the host, then brings the containers up (below), then runs the project's `up:`. |
| `dev down` | `container down`, then stops the engine if it is dev's and nothing else runs in it. |
| `dev container up` | Engine up and sized. Then per image: resolve the image; if it `persist`s, create or restart its container; align the container's user with the data root's owner; install dev inside at the host's version; run `dev deps install` inside. |
| `dev container down` | Stop this checkout's containers (`stop -t 0`) and keep them. The engine stays up. |
| `dev container reset` | Remove this checkout's containers. The next command creates a fresh one. |
| `dev container status` | Per image: the image locally and in the registry, its floor, its container and state, stale siblings. |

What survives what:

| After… | Image | Container (writable layer) | Engine |
|---|---|---|---|
| `dev down` | kept | kept, stopped | stopped if idle and dev's |
| `dev container down` | kept | kept, stopped | running |
| `dev container reset` | kept | removed | running |
| `dev engine down` | kept | kept, stopped (every checkout) | stopped |
| an `image` block or lock change | new tag pulled or built on next use | old one reaped on next use | running |
| `docker image rm` / `dev cache gc` | re-pulled or rebuilt on next use | kept while the tag is live | running |
| `dev up --no-cache` | kept | untouched | running |

Every container dev starts carries labels (`dev.managed=true`,
`dev.project_root`, `dev.project`, `dev.workspace`, `dev.image`). dev
operates on containers by label, never by name; a container without the
labels is yours as far as dev is concerned.

## Inside the container

Every dev-created container has `DEV_INSIDE_CONTAINER=1` in its
environment. A dev process reads that one marker to know where it is.

At creation the container gets:

- **A data root at `/var/lib/dev`** and a named volume at Linuxbrew's
  prefix. On a Mac the data root is a named volume of its own (the VM
  boundary makes a bind mount too slow). On Linux the host's data root is
  bind-mounted at its own path, so host and container share one store.
  The Linuxbrew volume is per host user on Linux (`dev-linuxbrew-<user>`).
- **The host's user ids.** The image's user takes the ids the data root
  calls for — on Linux, the host caller's uid in the root's group — so what
  the container writes belongs to the caller outside. Design notes:
  [ADR-0006](DECISIONS.md#adr-0006--the-build-container-runs-as-the-hosts-user).
- **The host's dev at the host's exact version**, installed through
  Linuxbrew into the prefix volume on first use and whenever the version
  differs.

Inside, a command runs directly through `shadowenv exec` in the
container's own workspace — a checkout of the snapshot the host handed it,
not a bind mount of the host's tree. Activation files the container
writes land beside the host's as `_container` siblings
(`515_brew_container.lisp`), inert on the host. `dev up` inside is the
dependency install alone; `dev deps install` inside installs the whole
Linux lock against the container's data root.

## The host rule

Was this host provisioned from the command's image? The image build writes
`/etc/dev/environment` with the image's name and digest; a host baked from
the image carries it, a container dev made carries its image's, a bare
machine carries none. The host runs the image's commands natively exactly
when its marker matches the lock's pin — same name, same digest — and
inside the image otherwise.

- **Marker matches** (a cloud worker baked from the image, a WSL distro
  imported from it, a container dev created): `dev up` says so, installs
  the lock on the host, and touches no engine or container for that
  image.
- **No marker, or another image's** (a Mac, a stock Linux runner): `dev
  up` brings the container up and every command on that image runs inside.
- **Drift** (the marker names the image under another digest): treated as
  not provisioned. `dev up` names both digests and brings the container
  up; re-imaging the host is its owner's job. Inside a drifted container
  the same comparison is an error pointing at `dev container reset && dev
  up` on the host.

A host designated publisher (`DEV_PUBLISH_IMAGE=1`) resolves and pushes the
image without running anything in it.

## The cold run

A warm machine hides a broken cold path. `dev up --no-cache` provisions
the project half of `dev up` from nothing, without touching the warm store
or the persistent container:

1. a throwaway data root is created beside the warm one and used for the
   run, tool download caches included;
2. the host-side `dev deps install` runs into it;
3. the image is resolved as usual, then a one-shot container over the
   throwaway root gets dev installed and runs the container-side install;
4. the throwaway root is removed.

Nothing is kept. Run it on a schedule to prove the project still
provisions on a fresh machine. The host layer is not converged, and the
flag has no meaning inside a container.
