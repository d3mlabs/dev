# What dev writes into a checkout

dev writes two kinds of file into a project's tree. Files that are the
project's declaration or lock are committed. Files that point at this
machine — activation lisps, symlinks into the data root, compiled trees —
are gitignored. This page is the full list, with the command that writes
the ignored half and the command that checks it.

The two files you write yourself, `dev.yml` and `dependencies.rb`, are
committed like any source file. Everything below is written by dev.

## Ignored

Every path here names something on one machine. Removing one costs
nothing: the next `dev up` writes it again.

| Path | Written by | What it holds |
|---|---|---|
| `.shadowenv.d/` | `dev up`, for every `dependencies.rb` directive that activates something (`ruby`, `python`, `brew`, `lua`, `llvm`, a `gh` tree with a `bin/`) | Activation lisps naming this machine's kegs, gem home and venv by absolute path |
| `.shadowenv.d-container/` | `dev up` inside the build container | The container side's lisps; mounted over `.shadowenv.d/` inside the container |
| `.venv` | `dev up`, with a `python` | Symlink to `<data root>/venv/<name>/host/<keg>` |
| `.venv-container` | `dev up` inside the build container, with a `python` | Symlink to `<data root>/venv/<name>/container/<keg>` |
| `build/_deps/` | `dev up`, with a `cmake` | One `<name>-src` symlink per dependency, to `<data root>/cmake/<host>/<path>/<sha>` |
| `lua_modules/` | `dev up`, with a `luarocks` | Rocks compiled for the locked Lua on this OS/arch |
| `.cursor/rules/org-invariants.mdc` | `dev learnings sync`, and the hooks that run it (`dev up`, `dev deps install`, `dev plan`) | Symlink to the machine-side render of the org knowledge repo's invariants, `~/.local/share/dev/org-invariants.mdc` |
| `.agents/skills/dev/` | `dev up` / `dev deps install` | Symlinks to the skills shipped by the locked gem set, one per `<integration>/<package>/<skill>` |
| `.cursor/plans/` | `dev plan new`, `dev plan link`, `dev plan pull` | Local working copies of plans; the GitHub issue is the canonical copy |

The container-side entries exist only on a Mac with a build container. The
list is unconditional: a Linux-only project ignores them for nothing, and
the next Mac contributor is covered. The same holds for a project that
declares no `python`, `cmake` or `luarocks`.

`.venv` and `.venv-container` are listed without a trailing slash. git
matches a `name/` pattern against directories only, and a symlink is a file
to git, so `.venv/` would ignore nothing.

`.agents/skills/dev/` also carries its own `.gitignore` (`*`). The
repo-level line is still required: without it `git status` lists the
directory and `git add -A` tries to add it.

## Committed

| Path | Written by | What it holds |
|---|---|---|
| `deps.lock` | `dev deps update` | Every pin `dependencies.rb` resolves to |
| `.ruby-version` | `dev up`, with a `ruby` | The locked Ruby, for tools that read the file (RubyMine, setup-ruby, Bundler's `ruby file:`). Rewritten from the lock every run; change `dependencies.rb`, not this file |
| `Gemfile`, `Gemfile.lock` | `dev deps update`, with `gem` declarations | The bundler view of the declared gems; `bundle install` reads them |
| `deps.cmake`, `deps.targets.cmake` | `dev up`, with a `cmake` | The locked repo, sha, url, hash and targets of each CMake dependency, for the project's own CMake to read |
| `.cursor/rules/learnings-index.mdc` | `dev learnings init` | The repo's always-on learnings index |
| `.github/ISSUE_TEMPLATE/plan.md` | `dev plan init` | The plan template mirror, when the repo uses one |

## The block

```gitignore
# dev-managed paths — rematerialized by `dev up` / `dev deps install` / `dev plan`, never committed
.shadowenv.d/
.shadowenv.d-container/
.venv
.venv-container
build/_deps/
lua_modules/
.cursor/rules/org-invariants.mdc
.agents/skills/dev/
.cursor/plans/
```

## Writing and checking it

```bash
dev learnings init --gitignore   # write the lines git does not already ignore; commit the diff
dev learnings status             # one warning per path git does not ignore
```

`dev learnings init --gitignore` asks git about each path and adds only
the ones nothing ignores yet, under the header above. A path your own
pattern already covers is left alone: a repo ignoring `build/` gets no
`build/_deps/` line. Lines you wrote are never moved or rewritten; an
existing dev block takes the new lines at its end. Re-running is a no-op.

`dev learnings status` warns for every path on the list. `dev skills
status` and `dev plan status` each warn for the path they own. Every
warning names the repair: `run \`dev learnings init --gitignore\``.

Why the activation state is one directory per side of the build container,
and why the venv and the cmake sources live in the data root rather than
the tree: [What the checkout carries, and gitignores](deps-channels.md#what-the-checkout-carries-and-gitignores)
and [Data root](data-root.md).

## Where the list lives in code

The list above mirrors constants in dev; the page is not a second source.
Each ignored path is a `GITIGNORE_FOOTPRINT` constant beside the path it
covers, and `Dev::Footprint::MANAGED_PATHS` collects them. A rename of a
constant is a change to this page.

| Path | Owner |
|---|---|
| `.shadowenv.d/`, `.shadowenv.d-container/` | `Dev::BuildContainer::GITIGNORE_FOOTPRINT` (`SHADOWENV_DIR`, `CONTAINER_SHADOWENV_DIR`) |
| `.venv`, `.venv-container` | `Dev::ShadowenvPython::GITIGNORE_FOOTPRINT` (`HOST_VENV_DIR`, `CONTAINER_VENV_DIR`) |
| `build/_deps/` | `Dev::Deps::CmakeIntegration::GITIGNORE_FOOTPRINT` (`SOURCES_DIR`) |
| `lua_modules/` | `Dev::Deps::LuaRocksIntegration::GITIGNORE_FOOTPRINT` (`INSTALL_DIR`) |
| `.cursor/rules/org-invariants.mdc` | `Dev::Learnings::Layout::GITIGNORE_FOOTPRINT` |
| `.agents/skills/dev/` | `Dev::Skills::Layout::GITIGNORE_FOOTPRINT` |
| `.cursor/plans/` | `Dev::Plan::Workspace::GITIGNORE_FOOTPRINT` |
| the header line | `Dev::Footprint::HEADER` |
