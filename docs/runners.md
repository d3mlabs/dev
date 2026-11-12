# Runners

`dev runner` enrolls a machine as a GitHub Actions self-hosted runner and
converges everything the jobs landing on it will need. This page also
covers how each kind of build host — workstation, box, hosted runner —
gets warm.

## dev runner

```bash
dev runner register                       # repo scope; label = the repo name
dev runner register --labels ue-engine    # repo scope, custom label
dev runner register --org --ai-flow       # org agent host: ai-flow's label set and runner group
dev runner register --org --ai-flow --slots 3           # three jobs at once
dev runner register --org --labels ai-orchestrator --slots 8   # the orchestrator pool
dev runner register --org --labels ue-engine --group ue-hosted # org pool in a human-made group
dev runner status                         # this machine's enrollments and host facts
dev runner unregister d3mlabs             # by scope …
dev runner unregister ~/actions-runner    # … or by directory (Tab completes both)
```

Enrollment is a machine fact, not a repo one: nothing is recorded in
`dev.yml` or any inventory file. Labels live on GitHub; the scope lives in
the runner directory's own `.runner` record. `dev runner status` reads
both back.

### Scope

**Repo scope** (the default) makes a runner only that repo's jobs land on.
Use it when a repo needs its own hardware or its own concurrency cap: a
repo whose jobs hold the one Unreal editor enrolls one repo-scoped runner
and has concurrency 1 by construction.

**Org scope** (`--org`) pools: every repo the runner group admits may send
jobs. The ai-flow work of every adopting repo is the same profile, so one
org host serves them all.

GitHub routes a job to any online runner visible to the repo whose labels
cover the job's `runs-on`. There is no repo-beats-org priority, so an org
host and a repo-scoped runner sharing a label pool their capacity.

### Labels

Workflows demand labels (`runs-on: [self-hosted, <label>]`); enrollments
supply them. Three vocabularies:

- **A repo's own label**: its name as GitHub spells it, lowercased
  (`d3mlabs/cellbound-3d` → `cellbound-3d`). Bare `dev runner register`
  uses it; `--repo a/b` moves it.
- **Custom labels** through `--labels`, for special fleets (`ue-engine`).
- **The ai-flow vocabulary**: `--ai-flow` enrolls the agent set (`ai-ask
  ai-edit ai-split ai-build ai-learn`, one per slash command) in the
  `ai-flow` runner group. `ai-orchestrator` is separate: the host
  `/build --split`'s orchestrator runs on, which polls for hours and
  belongs on an always-on box with many cheap slots, never on an agent
  slot. A `--labels` set mixing the two is refused.

A capability label is an obligation: `register` converges what each label
requires. A plain target-host label converges nothing; the agent labels
run the [agent host bootstrap](#agent-hosts).

### Slots

A runner runs one job at a time. `--slots N` enrolls N runners —
`<name>`, `<name>-2`, … — each with its own directory and service and the
same labels. Re-running without `--slots` keeps the size it finds; a
smaller number lists the surplus and asks before retiring it. `dev runner
status` reports a family as one header per scope (`d3mlabs — 3 slots`).

One host may hold two families at one org scope (the agent set and the
orchestrator pool). The second takes the name `<hostname>-<first label>`;
`register` sizes and retires only the family it was asked for.

### Runner groups

A runner group says which repos may use an org host's slots. Labels say
what a host can do, slots how many jobs it runs at once, the group who may
send them.

- `--ai-flow` implies the `ai-flow` group. `register` creates it when the
  org lacks it — visibility *selected*, restricted to ai-flow's two
  reusable workflows — and re-converges it when the console drifted.
- `ai-orchestrator` implies the `ai-orchestrator` group, visibility *all*.
- `--group <name>` is for human-made pools; the group must already exist.

Admission is derived from the checkout: `dev runner register --org …` run
in a repo (or with `--repo a/b`) admits that repo to the slots' group. Run
it once per adopting repo.

**A public repository may only use a group restricted to workflows**; a
fork's pull request could otherwise run arbitrary code on the host.
Admitting a public repo to an unpinned group is refused.

When `dev runner register --ai-flow` in a checkout finds that repo already
admitted to the org `ai-flow` group, it says the two would pool and asks
whether to make this host's runner the repo's only one (`--yes` answers
yes; headless the answer is no). Keeping both is legitimate.

### The enrolled runner

Bare `dev runner register` makes the repo's **enrolled runner**: repo
scope, the repo's name as label. The lifecycle verbs dispatch to it from a
machine that is not a build's environment when nothing else is named
(`--runner <label>`, then the `lifecycle.runner` setting, then the
enrolled runner, then the project's container). "Available" is read from
the Actions API each time: a runner at the repo's scope with that label,
online. Busy counts; offline does not. See
[Lifecycle](lifecycle.md#dispatch-resolution).

### What register does

1. **The engine**, when the checkout pins an `image`: the same step as
   `dev up`'s, sized from this repo's `engine:` hint
   ([Containers](containers.md#engine-resources)).
2. **Platform facts**: the Linux [runner user](#linux-the-runner-user),
   the [WSL2 keepalive](#wsl2), the [agent host](#agent-hosts) when agent
   labels are advertised.
3. **The enrollment.** An existing enrollment at the scope has its labels
   amended in place on GitHub; re-running is the no-op and the drift
   repair. Only a scope nothing serves gets the full ceremony: download,
   registration token through your `gh` auth, `config.sh --unattended`,
   service install. A repo-scoped runner re-registered `--org`
   deregisters at its old scope first.

Register never takes over another runner's registration. Runner names are
unique per scope; a name held by a registration that is not this host's
own is refused, naming the holder — pass `--name` to enroll beside it.

Two states make register stop and ask before enrolling fresh (`--yes`
answers; headless the answer is no, and the by-hand `dev runner
unregister <dir>` lines are printed): more than one local enrollment for
the scope, or GitHub listing the runner offline.

Flags: `--org`, `--repo`, `--ai-flow`, `--slots`, `--group`, `--yes`,
`--labels`, `--dir`, `--name`, `--agent-user`, `--as` (the Linux runner
user's name). `--org` needs no checkout; bare register does.

### Linux: the runner user

On Linux the enrollment belongs to a dedicated user, `runner` by default
(`--as <user>` renames it), with no sudo, no password and no access to
your home. The runner user owns the enrollment directory, the service's
identity, and the `gh` login jobs fetch private dependencies with; you
mint the registration token and install the service unit. A job never runs
with your credentials.

Before enrolling, register converges in one sudo session: the shared
[data root](data-root.md#the-linux-root-is-shared), the runner user (in
groups `docker` and `dev`), Homebrew's shellenv in
`/etc/profile.d/linuxbrew.sh`, brew's prefix handed to the runner user
(jobs upgrade dev through brew, and brew has one owner), and the
deployment tap trusted by the runner user.

Then register logs the runner user in to gh. At a terminal it asks for a
**machine user's** token — a dedicated account with read access to what the
jobs fetch, never an admin's — and hands it to `gh auth login
--with-token` on stdin; dev never stores it. Headless it prints the command
and stops: `sudo -iu runner gh auth login --with-token`.

With a checkout, register checks the runner user can reach every `gh` pin's
repo and every image's floor package, and refuses to enroll while one is
unreachable, printing the grant to make. `dev runner status` reports the
same under **Host reach**.

After the handover, package work on that host is `sudo -iu runner brew …`
and `sudo -iu runner dev up`; your own `dev up` there skips the brew layer.
An enrollment owned by anyone but the runner user is drift and is
re-enrolled as the runner user on the next `dev runner register`.

Macs have no runner user: the service is your LaunchAgent.

### WSL2

A WSL2 distro stops ~20 s after its last client session ends, and systemd
units inside are not sessions, so after a reboot nothing starts the
runner. Inside a WSL2 distro register also converges:

- a **logon keepalive** — a Task Scheduler task,
  `Start-WSL-<distro>-Runner`, that holds a client session
  (`conhost.exe --headless wsl.exe -d <distro> -u root -- sleep infinity`)
  with no time limit;
- **systemd** in `/etc/wsl.conf`;
- the **`.wslconfig` ratchet** for the checkout's `engine:` hint.

These need Windows interop, which only a shell opened on the Windows
desktop has; from a service or an ssh login register refuses and says
where to run. Enabling systemd or growing the VM needs `wsl --shutdown`
from Windows, then `dev runner register` again, then
`Start-ScheduledTask -TaskName 'Start-WSL-<distro>-Runner'` (or a log off
and on) to bring the distro back under the keepalive. `dev runner status`
reports all of this under **WSL runner host**.

### Agent hosts

Agent labels (`ai-ask`, `ai-build`, …) mark the host as one that runs an
AI agent in jobs. Register converges, idempotently and with admin
prompts:

- a non-admin **agent user**, `ai-agent` (`--agent-user` renames it), with
  its own home and no sudo;
- the **`dev` group** with both the runner identity and the agent in it;
- two **sudoers edges**: runner user → agent (`NOPASSWD:SETENV`), so the
  service spawns the agent; and agent → the brew prefix owner for exactly
  `<prefix>/bin/brew`, so the agent's `dev deps install` can install
  formulae;
- the shared **data root** (provisioned on a Mac, asserted on Linux),
  brew's lock directory as a group space, and the deployment tap trusted
  by the agent user;
- on a Mac, the agent's own **colima** engine when the repo pins an
  image. On Linux there is no agent engine: the agent for an image-built
  repo runs inside the project's container, and until that lands a Linux
  host refuses to serve agent labels for such a repo;
- after enrollment, the `_work` tree as a group space, and the **runner
  service environment**: umask 002, `AI_FLOW_AGENT_USER`,
  `AI_FLOW_AGENT_GROUP`, `AI_FLOW_RUNNER_SLOT`.

Last, warn-only, whether the agent CLI (`cursor-agent`) is installed in
the brew prefix. It arrives through the org Brewfile on the prefix owner's
`dev up` — yours on a Mac, `sudo -iu runner dev up` on Linux.

### dev runner status

The machine's view, framed at a terminal and plain through a pipe: every
enrollment with its scope, name, directory, who it runs as, and its labels
as GitHub holds them; on Linux a **Host identity** section (runner user,
brew prefix owner, the runner user's gh login and token expiry); each
agent enrollment's contract re-derived (agent user, groups, sudoers edges,
`_work` grant, data root, engine); **WSL runner host** facts; host tooling
against the org Brewfile; and, in a checkout, whether that repo may use
the slots and whether the host can reach its dependencies.

A job nobody picks up sits at *Waiting for a runner to pick up this job…*
under a `Requested labels:` line, the same whether the runners are busy,
offline, in a group that does not admit the repo, or never enrolled; it is
cancelled after 24 hours. Check the job's labels against the org's Runners
page: an idle runner carrying every one of them, in a group that admits
the repo.

### dev runner unregister

```bash
dev runner unregister [<scope> | <dir>] [--yes] [--org]
```

Names an enrollment by scope (`d3mlabs`, `JPDuchesne/snappy` — every slot
this host has there) or by directory (one slot). No argument means the
checkout's scope. It asks, then stops and uninstalls the service, removes
the registration with a token minted at the enrollment's scope, and clears
the enrollment files. The runner binaries stay, so a later `register
--dir` reuses the download.

## Build hosts, cold to warm

`dev up` satisfies the lock against the host's data root and installs the
difference. The host's job is to bring a data root to the start line.

| Setup | What persists the data root | Cold | Warm |
|---|---|---|---|
| **Host provisioned from the environment's image** (a cloud worker or WSL distro baked from it) | its disk | `dev up` installs the whole lock on the host; no container | `dev up` is a probe |
| **Linux host not provisioned from it** (the box, a stock hosted runner) | its disk, at `/var/lib/dev` | `dev up` creates the root, converges docker, pulls the image, installs the lock, starts the container over the host's own root | probe on both sides |
| **Mac** | the Mac's disk, and named volumes in the colima VM for the container | `dev up` installs the darwin lock on the host, then the Linux lock inside the container's volumes | probe on both sides |
| **Self-hosted runner** (a box) | its disk | Homebrew + dev, `gh auth login`, `dev runner register` | probe; several branches stay warm at once; `dev cache gc --keep N` per job trims |
| **Hosted runner** (GitHub larger runner) | a **checkpoint**: a custom runner image of the disk after `dev up` | Homebrew + dev, `dev up` installs the full lock — minutes to tens of minutes | boots the checkpoint; `dev up` is a probe |

### The hosted recipe

A hosted runner's disk does not persist, so its warmth is a checkpoint
minted by a `main`-only job. cellbound-3d's `ci.yml` is the reference.

- **Tests** (the project's job): `runs-on` the hosted runner;
  `actions/checkout`; install Homebrew + dev if missing (a no-op on the
  checkpoint); `dev up`; the project's commands. The job neither knows nor
  declares that it runs on a checkpoint.
- **checkpoint**: `needs: tests`; a job-level `if:` for `main` and for a
  lock file having changed; `snapshot: <image-name>`; body = the same
  bootstrap → `dev cache gc` → `docker logout` → empty the checkout (`find
  "$GITHUB_WORKSPACE" -mindepth 1 -delete`). The captured disk holds the
  data root, Linuxbrew and dev, nothing else.
- **Once, by hand**: enable image generation on the runner; let `main`
  mint the first version; bind the runner to the image at `latest`
  (`PATCH /orgs/<org>/actions/hosted-runners/<id>` with
  `image_source=custom image_id=<id> image_version=latest`).

A custom image is a block image of the whole disk, takes hours to
provision and is billed for as long as it is kept, so the job runs only
when a lock moved and an hourly workflow keeps the newest Ready version
and deletes the rest. Both are in cellbound-3d's `.github/workflows/`.
