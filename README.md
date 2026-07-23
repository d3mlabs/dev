# dev

Global CLI tool for d3mlabs projects. Discovers `dev.yml` in your git repos and executes declared commands like `dev up`, `dev build`, `dev test`, etc.

## Installation

Install via Homebrew (from the d3mlabs tap). This installs `dev` and shadowenv (for per-project Ruby env in repos that use `dev up`):

```bash
brew tap d3mlabs
brew install d3mlabs/dev
```

### System dependencies

`dev` shells out to a few external tools during `dev up` / dependency installs.
A fresh machine is often missing some, and each surfaces as a mid-run failure,
so install them up front:

```bash
# macOS and Linux (Homebrew):
brew install gh zstd            # gh: gated GitHub release downloads; zstd: engine .tar.zst extraction

# Linux runners only (git/curl preinstalled on macOS; lib32gcc-s1 = 32-bit support for SteamCMD):
sudo apt-get update && sudo apt-get install -y git curl sqlite3 lib32gcc-s1

# gh must be authenticated — dev pulls gated assets (e.g. the custom Unreal Engine) with no explicit token:
gh auth login
```

Docker is also required for repos whose builds run in containers (e.g. `dev up`
building a prewarmed image): Docker Desktop on macOS / Windows+WSL2, or Docker
Engine on Linux.

**Ruby:** We use **rbenv** as the standard Ruby version manager. If you run `dev up` in a repo that needs Ruby, have rbenv installed first:

```bash
brew install rbenv ruby-build
# Then e.g. rbenv install 2.7.6  (version comes from the repo's dependencies)
```

After installing, add the shadowenv hook to your shell so project Rubies activate when you `cd` into a repo:

```bash
# Add to ~/.zshrc (or ~/.bash_profile / config.fish)
eval "$(shadowenv init zsh)"
```

dev also ensures this hook (and the `dev cd` hook below) automatically and idempotently when you run `dev up` in a project, so a manual edit is only needed if you want it before your first `dev up`.

### Ruby version resolution

dev resolves a project's Ruby version in this order:

1. `ruby "x.y.z"` in `dependencies.rb` (see [Dependency management](#dependency-management)) — the standard place for repos with a deps manifest.
2. `ruby:` in `dev.yml` — for repos without a deps manifest (dev itself, small gems).
3. Homebrew Ruby — fallback when neither declares a version.

On `dev up`, dev provisions the resolved version through rbenv (installing it if needed) and generates two artifacts at the repo root:

- **`.shadowenv.d/510_ruby.lisp`** — the per-project environment. Contains machine-specific absolute paths; always gitignored.
- **`.ruby-version`** — the standard rbenv pin, so everything that is not shadowenv-aware (a plain rbenv shell, RubyMine's SDK detection, Bundler's `ruby file:`, GitHub's setup-ruby) agrees with dev.

**Commit `.ruby-version` when the project declares its Ruby** (cases 1 and 2). It is deterministic generated output — same idea as a lockfile — and it is exactly what contributors without dev consume. Do not commit it for fallback-Ruby repos (case 3): there it reflects whatever Ruby the machine happens to have.

Keep the file a bare version string. rbenv only reads the first word, but other consumers (setup-ruby, Bundler, editors) parse the file strictly, so comments would break them. There is no drift risk in the other direction either: `dev up` rewrites the file from the declared version every run, so a hand edit never survives — to change the Ruby, edit `dependencies.rb` (then `dev update-deps`) or `dev.yml`, and run `dev up`.

### Supported shells

All dev shell RC hooks — shadowenv activation and the `dev cd` wrapper + completers — are installed for **zsh, bash, and fish** (`~/.zshrc`, `~/.bash_profile` or `~/.bashrc`, `~/.config/fish/config.fish`). Other shells are unsupported for hooks: `dev` project commands still run, but there is no env activation and no `dev cd`.

**Formula maintainers:** The Homebrew formula for `d3mlabs/dev` should include `depends_on "shadowenv"` so developers get shadowenv when they install dev. Formulas must never edit shell RCs — dev installs its hooks itself on its own command paths (`dev up`, `dev cd`).

## Usage

From anywhere under a git repo that has a `dev.yml` at its root:

```bash
dev up       # Run the 'up' command (e.g. setup)
dev build    # Run the 'build' command
dev test     # Run the 'test' command
dev          # List all available commands
```

The tool walks up from your current directory until it finds a git repo root (directory containing `.git`), then looks for `dev.yml` there. If found, it parses the commands and executes the `run` string for your chosen subcommand.

A few builtins are global and work from **any** directory, no `dev.yml` needed: `dev cd` (host-global navigation), `dev cred` (host-global credentials), and `dev plan` (workspace-global plan sync). Project commands (`dev up` and anything declared in `dev.yml`) still require a nearby `dev.yml`.

## dev cd — jump between checkouts

`dev cd <repo>` jumps to a local checkout under your search root by short name, with fuzzy matching and Tab completion:

```bash
dev cd myrepo              # unique fuzzy / substring match → cd there
dev cd d3mlabs/myrepo      # explicit org/repo when names collide
dev cd d3m/d               # fuzzy each side of / → e.g. d3mlabs/dev
dev cd myr<TAB>            # interactive complete: list matches, select or refine
dev cd <TAB>               # empty prefix → list all candidates
```

The search root is `$DEV_CD_ROOT`, defaulting to `~/src` with the conventional `~/src/github.com/<org>/<repo>` layout. If your checkouts live elsewhere, set the override in your shell RC (or the current session) before calling `dev cd`:

```bash
export DEV_CD_ROOT=/path/to/checkouts
```

Only git repos count as candidates (directories with a `.git` entry — a `.git` file from a worktree checkout works too); plain folders are skipped. The query is a right-anchored path suffix matched per segment: `dev` matches the leaf, `d3mlabs/dev` the org and leaf, `bitbucket.org/d3mlabs/dev` the host too — a more explicit path always works. On an ambiguous query, `dev cd` lists the candidates (each at the shortest depth that makes it unique, capped at 10) and exits non-zero; refine the query or press Tab to browse all matches. On no match it errors clearly.

### Shell hook install

`dev cd` needs a small shell wrapper — a Ruby child process cannot change your shell's directory. dev installs the wrapper function and Tab completers into your shell RC automatically and idempotently: on `dev up` in any project, and on `dev cd` itself (so a first `dev cd` self-heals the hook; open a new shell after the install hint). The snippet is marker-guarded (`# dev cd (added by dev)`) next to the shadowenv one, and re-runs never duplicate it.

Tab completion is registered per shell: zsh gets a navigable menu-select list scoped to the `dev` command only (your other commands' completion is untouched; registration is skipped quietly if your zshrc never runs `compinit`), bash fills `COMPREPLY` directly, and fish registers a standard pager completion (fish applies its own filtering, so fuzzy tokens may only complete literally there). Completion fills the argument only — it never runs the `cd` for you — and inserts `org/repo` (or deeper) forms when a short name would collide.

Because the wrapper runs `builtin cd` in your interactive shell, shadowenv activation after `dev cd` behaves exactly like a manual `cd`: if the shadowenv hook is in your RC (see above), the project env loads; if it's missing, `dev cd` still changes directory but no env activates — same as plain `cd`.

## Child script UI

Dev uses `Kernel.exec` to replace itself with the child command. This gives the child full, direct terminal access — no pipes, no PTY, no output interception.

Dev prints a colored header (the command name) before exec-ing. For non-repl commands, a shell wrapper runs after the child exits and prints `✓ Done` or `✗ Failed` based on the exit code. Commands marked `repl: true` exec directly without a wrapper (for interactive sessions like consoles).

### How it works

Ruby child scripts use [Shopify's cli-ui](https://github.com/Shopify/cli-ui) natively for frames, spinners, prompts, and colors. Since the child IS the process (not a subprocess), all CLI::UI features work without compromise — animated spinners, interactive prompts, password inputs, menus.

Shell scripts output plain text. No special markers or protocol needed.

### Running subcommands from child scripts

Since the child process has full terminal access, `system()` is the simplest and best default for running subcommands — the subprocess inherits the TTY, so colors, prompts, and interactive output all work.

Use `Open3.capture3` instead when running a subcommand **inside a `CLI::UI::Spinner`**. The spinner uses StdoutRouter to capture output while it animates; `system()` writes directly to the terminal file descriptor (bypassing StdoutRouter), which causes output to leak past the spinner and produce garbled text. `capture3` redirects the subprocess's stdout to a pipe so the spinner stays clean.

```ruby
# Outside a spinner — system() is fine
system("cmake", "--build", "build")

# Inside a spinner — use capture3 to prevent output leaking
CLI::UI::Spinner.spin("Installing bundler...") do
  out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
  raise "install failed: #{err}" unless status.success?
end
```

### Environment behavior

| | Ruby scripts (with cli-ui) | Shell scripts |
|---|---|---|
| Dev terminal | Full CLI::UI: frames, colors, animated spinners, prompts | Plain text |
| CI (no TTY) | CLI::UI degrades gracefully (no animation, basic formatting) | Plain text |
| Cursor sandbox | Same as dev terminal (use `dev <cmd>` per `.cursor/rules/dev.mdc`) | Plain text |
| Without dev | CLI::UI renders directly to terminal | Plain text |

### Ruby / environment resolution

| | How Ruby resolves |
|---|---|
| Dev terminal | `dev` uses Homebrew Ruby (shell trampoline in `bin/dev`). Child commands get the project's Ruby via `shadowenv exec --`. |
| CI | Docker image provides Ruby. Scripts run directly (not via `dev`). |
| Cursor sandbox | `dev <cmd>` resolves Ruby correctly. `.cursor/rules/dev.mdc` instructs the AI agent to always use `dev <cmd>`. Shell trampolines in child scripts are NOT needed — only `d3mlabs/dev`'s own bin/ scripts need them (bootstrapping: can't use `dev` to run `dev` itself). |

## dev.yml convention

Each repo that wants to support `dev` should have a `dev.yml` at its git root:

```yaml
name: myproject

commands:
  up:
    desc: Setup dev environment
    run: ./bin/setup.rb
  build:
    desc: Build the project
    run: ./bin/build.sh
  test:
    desc: Run tests
    run: ./bin/test.sh
  console:
    desc: Start Ruby console
    run: ./bin/console
    repl: true
```

- `name`: Display name for the repo (used in help output).
- `commands`: Map of command names to specs.
  - Each command has:
    - `desc`: Short description (shown in `dev` / `dev --help`).
    - `run`: Shell command to execute (from the repo root). Any extra args passed to `dev <cmd> [args...]` are forwarded to this command.
    - `repl`: *(optional, default `false`)* When `true`, the command execs directly without a status footer. Use this for long-running interactive sessions like consoles and REPLs where a trailing `✓ Done` doesn't make sense.
    - `container`: *(optional, default `true` when `build.container` is configured)* When `false`, the command runs on the host (via `shadowenv exec`) instead of inside the build container. Use for host-side commands like provisioning (`up`) or deploying.
    - `hidden`: *(optional, default `false`)* When `true`, the command is still callable (`dev <cmd>`) but omitted from `dev` / `dev --help` output. Use for internal plumbing — e.g. a `build` primitive that an intent command (`test`, `release`) calls but that developers shouldn't invoke directly.

## Examples

```bash
# From repo root or any subdirectory
cd /path/to/myproject
dev up          # Runs ./bin/setup.rb
dev up -v       # Runs ./bin/setup.rb -v
dev test        # Runs ./bin/test.sh
dev build       # Runs ./bin/build.sh

# Help
dev             # Lists all commands
dev --help      # Same
```

## Error handling

- If no git repo is found above your current directory: `dev: no git repo (with dev.yml) found above <path>`
- If a git repo is found but has no `dev.yml`: `dev: found git repo at <path> but no dev.yml there`
- If you run an unknown command: `dev: unknown command: <name>` (and shows available commands)

## Dependency management

Dev includes a built-in dependency management system for reproducible builds across ecosystems.

### Lifecycle

Dependencies flow through four stages:

1. **Declare** — list what you need in `dependencies.rb` using the Ruby DSL
2. **Resolve & lock** — `dev update-deps` resolves constraints to exact versions and writes lockfiles
3. **Install** — `dev up` installs pinned dependencies from lockfiles (build group first)
4. **Use** — `dev <command>` provisions the project's toolchain environment and runs your command

Lockfiles are the source of truth for stages 3 and 4. After changing `dependencies.rb`, run `dev update-deps` to re-resolve before building.

### Lockfiles

Two YAML lockfiles, same format, two purposes:

- **`deps.lock`** — pins every runtime dependency (app + test groups) to exact version + SHA256 integrity hash.
- **`build-deps.lock`** — pins every build dependency (build group). Separate file for CI cache convenience — `hashFiles('build-deps.lock')` as Docker image cache key means runtime dep changes don't invalidate build tooling.

Both files are generated by `dev update-deps` and committed to git. Never edit them by hand.

### dependencies.rb

Declare dependencies using a Ruby DSL:

```ruby
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.5" # the project's Ruby toolchain; dev provisions it (rbenv + shadowenv)
  python "3.12" # optional Python toolchain; dev provisions the interpreter + a project .venv
  gem "cli-ui"
  tap "d3mlabs/d3mlabs"

  group :build do
    brew "cmake"
    brew "llvm", version: "22"
    env :ci do
      brew "ruby"
    end
  end

  group :app do
    cmake "boost",
          url: "https://example.com/boost-1.90.0.tar.gz",
          tag: "boost-1.90.0"
    cmake "cereal", github: "USCiLab/cereal", tag: "v1.3.2"
  end

  group :test do
    cmake "googletest", github: "google", tag: "v1.17.0",
          targets: ["gtest", "gmock"]
    luarocks "luaunit", ">=3.5"
  end

  # Python packages install into the project .venv (needs a `python` directive).
  # Heavy, host-specific toolchains gate with `host:` so they only land where used.
  group :anatomy, host: :darwin do
    pip "totalsegmentator", ">=2.0"
  end
end
```

### Dependency axes

Four orthogonal axes scope a declaration; each answers a different question:

- **`group`** — *purpose* (`:app`, `:test`, `:build`, `:game`, `:editor`, …). User-defined; `:build` installs first.
- **`env`** — *execution context* the dep is for (`"ci"` / `"dev"`), declared via `env :ci do ... end` inside a group. Filtered at install against the detected env (`CI` variable only — a Linux workstation is `dev`, a Mac CI runner is `ci`).
- **`host`** — *OS of the machine the dep installs on* (`:darwin` / `:linux`). Declared per-group (`group :editor, host: :darwin do ... end`) or per-declaration (`gh ..., host: :linux`). Filtered at install against the detected host OS — deps for other hosts are still resolved and locked, so the lockfile stays the single source of truth for every machine.
- **`platform`** — *what artifact variant the dep targets* (e.g. `"LinuxServer"`), for multi-arch integrations like ficsit. A resolve-time concern, not an install filter.

`env` and `host` describe *where/when a dep installs* and are first-class declaration fields; the constraint hash describes *what the dep is*.

### Built-in integrations

All built-in integrations are declared in one place — `lib/dev/deps/registry.rb` — and `dev install-deps` installs every host-scoped one. `registry_consistency_test.rb` fails the build if a repository/integration class or a declaration DSL verb is added without a registry entry.

| DSL method | Integration | Repository | Lockfile |
|---|---|---|---|
| `gem()` | BundlerIntegration | BundlerRepository | deps.lock |
| `cmake()` | CmakeIntegration | GitRepository / UrlRepository | deps.lock |
| `luarocks()` | LuaRocksIntegration | LuaRocksRepository | deps.lock |
| `brew()` | BrewIntegration | BrewRepository | deps.lock / build-deps.lock |
| `gh()` | GhIntegration | GhRepository | deps.lock |
| `ficsit()` | FicsitIntegration | FicsitRepository | deps.lock |
| `steam()` | SteamIntegration | SteamRepository | deps.lock |
| `xcode()` | XcodeIntegration | XcodeRepository | deps.lock |
| `pip()` | PipIntegration | PipRepository | deps.lock |

`xcode "26.1.1"` pins the Xcode toolchain (macOS only; a no-op on other hosts). dev installs the pin to `/Applications/Xcode-<ver>.app` via the [xcodes](https://github.com/XcodesOrg/xcodes) CLI — declare `brew "xcodes", host: :darwin` in `:build` so it exists first — and publishes `DEVELOPER_DIR` into the project shadowenv. Interactive runs pass any Apple ID/2FA/sudo prompt through to you; headless runs fail fast with remediation instead of hanging (normal practice: pre-install the pin interactively once during machine bring-up, e.g. a CI runner's).

`gem()` declares Ruby gems: dev generates a `Gemfile`/`Gemfile.lock` from your declarations (a top-level `gem` lands in the default group; `group(:test) { gem ... }` scopes it to a bundler group), and `dev install-deps` runs `bundle install`. `brew()` dual-writes — the container build path keeps reading the group structure while `dev install-deps` also installs the formulae on the host (idempotently).

`python "3.12"` pins the Python toolchain: dev provisions the interpreter (Homebrew `python@3.12`) and a project-local `.venv`, and publishes it into the project shadowenv (`VIRTUAL_ENV` + `.venv/bin` on `PATH`). `pip()` declares packages installed into that venv — like `luarocks()`, you declare only the top-level packages and pip resolves the transitive tree at install time. Gate heavy, platform-specific stacks (e.g. a PyTorch-backed ML tool) with `host:` so only the machines that use them pay the download.

### Custom integrations

Projects can register their own integration types:

```ruby
require_relative "lib/my_integration"

Dev::Deps.define do
  register :my_type, MyIntegration

  group :app do
    my_type "some_dep", version: ">=1.0"
  end
end
```

Custom integrations implement `Dev::Deps::Integration` (with `install_all(pins, root:)`) and `Dev::Deps::Repository` (with `resolve(name, constraint, cache:)`).

### github: shorthand

`github: "org/repo"` expands to `repo: "https://github.com/org/repo"`. If only org is given (`github: "org"`), the dep name is appended as the repo name.

### Built-in commands

- **`dev update-deps`** — resolve constraints from `dependencies.rb`, write lockfiles (recording the manifest digest for the staleness check). Always available (no need to define in `dev.yml`).
- **`dev install-deps`** — install locked deps handled on the host (gh releases, steam apps) into their version-keyed install dirs, filtered to the detected env and host OS.
- **`dev up`** — auto-installs all deps from lockfiles (build group first), then runs the project's `up:` command from `dev.yml` if defined. On success, stamps the installed lockfile digest (see `dev check`).
- **`dev check`** — report dependency-state staleness explicitly: `dependencies.rb` vs lockfiles (digest recorded by `update-deps`), and lockfiles vs the per-machine installed stamp (`~/.dev/state/<project>/installed-digest`, written after a fully-successful `up`/`install-deps`). The same two O(1) checks run at every command start — warning on workstations, erroring in CI.
- **`dev deps path <integration> <name> <platform>`** — print the absolute path of a locked artifact (e.g. `dev deps path ficsit SML LinuxServer`, or `dev deps path xcode` for the pinned DEVELOPER_DIR) so scripts don't reconstruct cache keys or layout conventions.
- **`dev cred get <namespace> <key>`** — resolve a credential through the provider chain (ENV → keychain → file → prompt) and print it. A non-interactive miss errors with `gh secret set` guidance. Mirrors `dev deps path` for shell consumers (e.g. a staging sync). Global: works without a `dev.yml`.
- **`dev cd <repo>`** — jump to a checkout under `$DEV_CD_ROOT` (default `~/src`) by fuzzy name, with Tab completion (see [dev cd](#dev-cd--jump-between-checkouts)). Global: works without a `dev.yml`.
- **`dev cache gc [--keep N]`** — reclaim host caches dev owns (see below).
- **`dev reset-container`** — remove the persistent build container (clears its incremental cache); registered only when `build.container.persist` is set.
- **`dev plan …`** — global (works without a `dev.yml`; the workspace is the nearest dev.yml or git root). Sync Cursor plans with GitHub issues (ai-flow): the issue is the canonical plan, the local `.cursor/plans/gh-<n>-<slug>.plan.md` is a transient working copy carrying an `<!-- ai-flow … -->` header. Subcommands: `new "<title>" [--org]` (create issue + linked plan; `--org` scaffolds a `Target repos:` line), `link <n> [<file>]` / `link <file>` (attach a draft to an existing issue / create one from it), `pull <n> [--merge]` (fetch, 3-way merging when both sides changed — the merge base lives at `~/.local/state/ai-flow/`), `push [<file>|<n>]` (guarded body PATCH — refuses to clobber newer remote edits; a number resolves the linked plan like `pull`), and `status` (clean / ahead / behind / diverged, per linked plan). `--org` targets the org plans repo (`plans_repo:` in `~/.config/dev/config.yml`, or `DEV_PLANS_REPO`) instead of the current repo's origin. Every invocation also ensures `~/.cursor/skills/ai-flow` symlinks to the skill shipped in `share/cursor-skills/`, so the Cursor agent knows these verbs. For auto-push, a participating repo adds a Cursor `afterFileEdit` hook to `.cursor/hooks.json` running `dev plan hook-after-edit` — it reads the hook payload from stdin and no-ops unless the edited file is a linked plan. What happens to a plan after it's canonical — `/ask`, `/edit`, `/split` (two-phase dry/apply), `/build` — is ai-flow's remote half: see [plan-lifecycle.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/plan-lifecycle.md) and [commands.md](https://github.com/d3mlabs/ai-flow/blob/HEAD/docs/commands.md).

## Build container & caching model

For repos that declare a `build.container`, dev builds and runs commands inside a content-addressed Docker image, backed by host-side caches it owns end to end. The guiding principle throughout is **content-addressing**: an artifact's identity is a hash of its inputs, so distinct versions coexist instead of overwriting, and identical inputs are never rebuilt.

### Content-addressed image tag

The image tag is `content-<hash>`, where the hash covers the `Dockerfile`, `.dockerignore`, both lockfiles, and any project-declared `content_globs` (file contents) / `structure_globs` (path set only). Any change to those inputs yields a new tag — and therefore a guaranteed rebuild — while an unchanged set is a guaranteed cache hit.

`ensure_image!` resolves the image in three steps, cheapest first:

1. **local** — a matching local image is honored as-is (manual builds work).
2. **pull** — otherwise pull the tag from the registry (the CI-produced image lands here).
3. **build** — only on a miss, build it locally.

**Publishing** is separate from resolution. The provisioning step opts in (set `DEV_PUBLISH_IMAGE=1`, as CI's `dev up` does) so the resolved image is pushed to the shared registry — and this runs **even on a local hit** (step 1), not only after a build. That local-hit case is the whole point: the machine that built the image (e.g. the CI runner) keeps resolving its own local copy on every run, so without publish-on-hit the registry it is meant to populate would stay empty and no other machine could ever pull. The push is registry-guarded (a remote manifest check), so it is a no-op once the tag is published. A normal local build/run leaves `DEV_PUBLISH_IMAGE` unset and never pushes.

### Prewarm

A large base dependency (e.g. a game engine) is too big to stream into a `docker build` (BuildKit's build-context transport stalls under emulation). Instead, dev builds a cheap engine-free **base** image from the `Dockerfile`, then runs the project's `prewarm:` command in a container with the dependency volume-mounted and `build_secrets` file-mounted at `/run/secrets/<id>`, and commits the result as the content tag. Secrets are bind-mounted (never `-e`), so `docker commit` can't bake them into a layer.

### install_dir content-addressing (version-keyed)

Multi-GB host deps (`gh` releases, `steam` apps) bypass the download cache and install under their declared `install_dir`, **keyed by version**:

```
<install_dir>/<version>/…        # immutable; one dir per locked version
```

Installs are **atomic and concurrency-safe**: dev builds into a unique same-filesystem staging dir, stamps a marker, then publishes via a single `rename`. First writer wins — a second concurrent installer of the same version sees the published dir and discards its staging, and dev never `rm_rf`s a live directory a running job may have mounted. Switching branches (different locked versions) never reinstalls, and different-version builds can run in parallel.

dev resolves the configured volume/build-context onto the right versioned subdir from the lockfile, so a `dev.yml` volume like `~/.dev/engines/unreal-engine-css:/ue` is mounted from `…/unreal-engine-css/<locked-version>` automatically.

### Hung-build watcher

The prewarm runs under a watcher that detects the intermittent emulated-compiler deadlock (container silent **and** ~0% CPU): it kills and retries a hang, retries a transient crash signature (e.g. a Rosetta/clang crash), and **fails fast** on a genuine compile error. Retries are capped and rely on the build tool's atomic intermediate writes, so a retry resumes incrementally.

### `dev cache gc`

dev owns the cache layout, so it owns reclamation. `dev cache gc [--keep N]` applies **size-tiered, safe** retention:

- **install_dir versions** (multi-GB) get a tight default keep. Locked versions (current lockfiles) and in-use versions (mounted by a running container) are **never** evicted; orphan staging dirs from a killed install are always reclaimed.
- **docker content tags** for the project image are pruned down to the live tag (never one backing a running container).

A workflow/cron only *schedules* `dev cache gc`; it never reaches into the layout itself.

## Releasing a new version

Releases are distributed via the Homebrew tap at [d3mlabs/homebrew-d3mlabs](https://github.com/d3mlabs/homebrew-d3mlabs).

The release script handles everything — version bump, commit, tag, push, GitHub release, sha256, and Homebrew formula update:

```bash
./bin/release.rb                     # auto-increment patch (0.2.24 → 0.2.25)
./bin/release.rb 0.3.0               # explicit version
./bin/release.rb "Fixed the widget"  # auto-increment with custom notes
./bin/release.rb 0.3.0 "Big update"  # explicit version + notes
```

Verify (on any machine with the tap):

```bash
brew update
brew upgrade d3mlabs/d3mlabs/dev
dev --help
```
