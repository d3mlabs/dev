# dev

Global CLI tool for d3mlabs projects. Discovers `dev.yml` in your git repos and executes declared commands like `dev up`, `dev build`, `dev test`, etc.

## Installation

Install via Homebrew (from the d3mlabs tap). This installs `dev` and shadowenv (for per-project Ruby env in repos that use `dev up`):

```bash
brew tap d3mlabs
brew install d3mlabs/dev
```

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

**Formula maintainers:** The Homebrew formula for `d3mlabs/dev` should include `depends_on "shadowenv"` so developers get shadowenv when they install dev.

## Usage

From anywhere under a git repo that has a `dev.yml` at its root:

```bash
dev up       # Run the 'up' command (e.g. setup)
dev build    # Run the 'build' command
dev test     # Run the 'test' command
dev          # List all available commands
```

The tool walks up from your current directory until it finds a git repo root (directory containing `.git`), then looks for `dev.yml` there. If found, it parses the commands and executes the `run` string for your chosen subcommand.

## Pretty UI (cli-ui) and protocol markers

Dev depends on [Shopify's cli-ui](https://github.com/Shopify/cli-ui) for frames, colors, and formatted output. All non-repl commands run as subprocesses with their output piped through a **line protocol parser**. The parser detects protocol markers and renders them via cli-ui; non-marker lines pass through as-is.

Commands marked `repl: true` bypass this entirely and replace the dev process (`exec`), giving the child command direct terminal access.

### Three-tier rendering

Dev adapts its output based on the environment:

- **TTY (terminal)** — detected via `$stdout.tty?` — full cli-ui: frames, colors, spinners
- **CI** — detected via `CI` or `CLICOLOR_FORCE` env var — frames and colors, no spinner animation
- **Pipe/file** — neither of the above — plain text fallback

### Protocol markers

Child scripts can output these markers (one per line) to control the parent dev process's UI rendering:

```
::frame::Title       Open a cli-ui frame
::endframe::         Close the current frame
::ok::label          Green checkmark + label
::fail::label        Red X + label
::warn::message      Yellow warning message
::spin::label        Start draining lines (hidden) until endspin
::endspin::          End drain, report success (ok)
::endspin::fail      End drain, report failure (fail)
```

Example child script (`bin/setup.sh`):

```bash
#!/bin/sh
echo "::frame::Dependencies"
echo "::ok::ruby 4.0.1"
echo "::ok::bundler"
echo "::fail::cmake (not found)"
echo "::endframe::"
```

This renders as a properly indented cli-ui frame with checkmarks and X marks, without the child script needing cli-ui as a dependency.

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
    - `repl`: *(optional, default `false`)* When `true`, the command replaces the dev process (via `exec`) instead of running inside a cli-ui frame. Use this for interactive commands like consoles and REPLs that need direct terminal access.

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
