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
