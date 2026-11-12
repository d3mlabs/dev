# Data root

Everything dev downloads, builds or caches lives under one directory, the
**data root**. A host is warm when its data root already holds what the
lock names; `dev up` installs only the difference.

## Location

| Host | Data root |
|---|---|
| `DEV_DATA_ROOT` set | that path |
| Linux | `/var/lib/dev` |
| macOS | `/Users/Shared/dev` when it exists (agent hosts), else `~/.dev` |
| inside a container | `/var/lib/dev` — the host's root bind-mounted on Linux, a named volume on a Mac |

Per-user mutable state (`~/.dev/state`) stays in the home directory and is
never shared.

### The Linux root is shared

`/var/lib/dev` is owned by whoever ran `dev up` first, in group `dev`,
mode `2775`: every user in the group writes it, and the setgid bit keeps
new entries in the group. On a host whose root is absent, `dev up` asks
for sudo once, creates the group and the directory, adds you to the group,
and moves `~/.dev` into it (except `state`). A root you cannot write
belongs to another identity; dev names the fix (`usermod -aG dev <user>`
and a new login) and never re-owns it.

Everything in the store embeds absolute paths — Unreal's build state is
warm only at the path it was compiled at, venvs record theirs — so one
tree must read the same from every account that builds on the host.
Design notes:
[ADR-0008](DECISIONS.md#adr-0008--a-data-root-belongs-to-a-build-host).

## Layout

| Path | Contents |
|---|---|
| `gh/<owner>/<repo>/<version>/` | GitHub release trees |
| `steam/<app id>/<version>/` | Steam depots |
| `wwise/<sdk>/` | Wwise SDK cache |
| `cmake/<host>/<path>/<sha>/` | CMake source checkouts, linked from `build/_deps/<name>-src` |
| `egs/<name>/<digest>/` | Epic's BuildPatchTool |
| `venv/<project>/<host\|container>/<keg>/` | Project venvs |
| `cache/<sha256>` | Content-addressed downloads (tarballs, mod archives) |
| `tool-caches/<tool>/` | Download caches handed to bundler, brew and pip |
| `artifacts/<project>/<build>/` | `install/`, the archive, and `build-id.json` from `dev build` / `dev package` |
| `artifacts/<project>/.<channel>/` | A deploy channel's scratch |
| `artifacts/<project>/.releases/v<version>/` | Verified downloads of a release's archives |
| `workspaces/<checkout>-<id>/` | A container's own checkout of a snapshot |

Trees are keyed by version and immutable: two projects locking the same
release share one tree, and switching branches never reinstalls. A tree is
published atomically (staged, then renamed), so two installers of the same
version never collide and a running job never sees a half-written tree.
`dev deps path <integration> <name>` answers where a tree is.

Tool caches are the tool's: dev names the location (`BUNDLE_USER_CACHE`,
`HOMEBREW_CACHE`, `PIP_CACHE_DIR`) and never reads or writes inside it. A
gem the host fetched is already cached when the container's `bundle
install` runs.

## dev cache gc

```bash
dev cache gc [--keep N] [--tool-caches]
```

Reclaims what no current lock names:

- **Store trees** — versions not in the lock and not mounted by a running
  container, keeping the newest `N`. Orphaned staging directories from a
  killed install are always removed.
- **Image tags** — every tag of a pinned image's repository other than the
  lock's, unless a running container uses it.
- **Stale prefix volumes** — Linuxbrew volumes whose name carries no host
  user, unless a container still mounts one.
- **Tool caches** — left alone by default; dropped whole with
  `--tool-caches`. Losing one costs a re-fetch, never correctness.
- **Snapshot branches** — `dev/build/<runner>/<id>` branches on `origin`
  older than seven days, left by a remote dispatch that died. An `origin`
  that cannot be reached is reported and skipped.

Venvs are not lock-named and are left alone. A workflow or cron only
schedules `dev cache gc`; a self-hosted runner typically runs it at the end
of each job with `--keep N`.
