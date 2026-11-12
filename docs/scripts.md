# Writing scripts for dev

How a project's `run:` scripts get the terminal, the environment, and the
Ruby they run under.

## The terminal is yours

dev `exec`s into the child command: no pipes, no PTY, no output
interception. dev prints a colored header first, and for non-`repl`
commands a wrapper prints `✓ Done` or `✗ Failed` after the child exits.

Ruby scripts can use [Shopify's cli-ui](https://github.com/Shopify/cli-ui)
directly — frames, spinners, prompts, passwords, menus all work, because
the script is the process. Shell scripts print plain text.

| Context | Ruby with cli-ui | Shell |
|---|---|---|
| terminal | full UI | plain text |
| CI (no TTY) | degrades: no animation | plain text |
| Cursor sandbox | full UI | plain text |

## Subprocesses: the spinner rule

`system()` is the default for running a subcommand; it inherits the TTY, so
colors, prompts and interactive output work.

**A child that may own the terminal never runs under a spinner.** A
`CLI::UI::Spinner` captures Ruby-level output and masks stdin while it
animates; a `system()` child writes to the terminal directly and garbles
the animation, and if it prompts (`sudo`, `gh auth login`, an OTP) it waits
on input nobody can see. Under a spinner, run only subcommands that never
prompt, captured with `Open3.capture3`.

```ruby
# Owns the terminal: outside any spinner
system("cmake", "--build", "build")

# Under a spinner: captured, never prompting
CLI::UI::Spinner.spin("Installing bundler...") do
  out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
  raise "install failed: #{err}" unless status.success?
end
```

A `CLI::UI::Frame` groups dev's own lines; a child's lines inside it are
not prefixed with the frame's bar.

## Which Ruby runs

| Context | Ruby |
|---|---|
| `dev <cmd>` | the project's locked Ruby, through `shadowenv exec` |
| CI inside the build container | the container's locked Ruby |
| without dev | whatever the shell has |

Always invoke project commands as `dev <cmd>`, not `./bin/<script>`; the
repo's `.cursor/rules/dev.mdc` tells agents the same. Only dev's own
`bin/` scripts need a shell trampoline, since dev cannot run itself to
run itself.

## Environment

dev strips a caller's bundler activation (`RUBYOPT`, `RUBYLIB`,
`BUNDLE_*`, `BUNDLER_*`) once, at its entrypoint, so running dev under
`bundle exec` does not boot it inside that bundle. Nothing else is
scrubbed: `GEM_HOME` and `GEM_PATH` pass through to children, and in a
project shell the project's shadowenv sets them. dev's own vendored gems
are added to its process's gem path, not exported, so they never leak into
a child.

Scripts under `build:`, `package:` and a channel's `run:` read their
parameters from `DEV_*` variables; see [dev.yml](dev-yml.md#the-build-scripts-environment).
