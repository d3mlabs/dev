# Plan: generalize dev's CLI UI

Status: proposal for review. No code beyond the bugfix noted in §0.

## 0. Shipped alongside this plan (not part of the proposal)

While investigating, two latent bugs surfaced and are already fixed:

- **`content_tag` Errno::EISDIR** — a recursive `content_globs` (`bin/image/**/*`)
  matched the `bin/image/lib` directory; `content_tag` now skips non-files
  before reading. (`lib/build_container.rb`, test added.)
- **`release.rb` clobbered resource sha256s** — a `gsub!` over every
  `sha256 "..."` overwrote vendored-gem resource checksums with the tarball sha;
  now anchored to the package url+sha pair. (`bin/release.rb`.)

Both ship in the next `dev` release.

## 1. Problem

dev has **four** disjoint ways to talk to the terminal, with no shared rules:

| Surface | Today | Issue |
|---|---|---|
| Core (`Dev::Cli::Ui`) | prints a bold header, then `exec`s | minimal; no shared vocab |
| Deps (`Dev::Deps::CliUI`) | `with_spinner`/`step_ok`/`step_fail` + plain fallback | **swallows failures** (see §3) |
| `bin/*.rb` (setup, release, …) | call `CLI::UI` directly (`frame`, `spinner`) | each re-derives router setup |
| Integrations / `BuildWatcher` / `install-build-deps` | raw `puts ">>> …"` | no spinner, no progress, no glyphs |

So the engine download on `dev up` prints flat `>>> Downloading…` lines while
`setup.rb`/`release.rb` right next to it render framed spinners. There's no
progress bar despite the lockfile carrying per-asset `size`, and no heartbeat
for long silent steps (the prewarm). Worse, the one shared helper
(`Deps::CliUI`) has a correctness bug around failure propagation.

## 2. Goals / non-goals

**Goals**
- One facade, `Dev::UI`, that every layer (core, deps, integrations, watcher,
  bin scripts) uses. Consistent look; one place for the footgun rules.
- First-class: status lines, frames, a **failure-propagating** step/spinner, a
  **progress bar** (known-size downloads), and a **docked heartbeat** for long
  silent work.
- CI-safe by construction: degrade to plain, newline-delimited, ANSI-free output
  with no spinners/progress-bar carriage-return spam.
- Testable without a TTY (injectable backend).

**Non-goals**
- No new UI dependency — build on the `cli-ui` gem already vendored.
- Not changing *what* commands do, only how they report.
- Not forcing bin scripts to migrate immediately (phased; §6).

## 3. Footguns to encode as invariants (hard-won lessons)

These are the rules the facade must make impossible to get wrong:

1. **Failure propagation.** `CLI::UI::Spinner.spin` returns a *bool* and, with
   `auto_debrief: true`, **catches the block's exception** (prints it, returns
   false). `Deps::CliUI.with_spinner` currently returns that bool and callers
   ignore it — so a failing step is silently swallowed in the CLI::UI path but
   *raises* in the plain-text path. The facade's `step` MUST converge both:
   capture the outcome and **re-raise (or abort) on failure**, so exit codes
   always propagate. A step's result is never silently dropped.
2. **chdir + output capture inside a spinner.** SpinGroup runs the block inside
   a `StdoutRouter::Capture`; combining that with a subprocess that changes
   directory and/or writes straight to the TTY has bitten us. Rule: subprocess
   helpers take an explicit `chdir:`; commands run *inside* a step are
   **captured** (`Open3.capture3`), never inheriting the TTY; commands that must
   own the TTY (e.g. `gh`'s own progress bar) run **outside** any step.
3. **StdoutRouter lifecycle.** Frames/spinners need `StdoutRouter.enable`. It
   must be enabled **once**, centrally and lazily (idempotent guard), not
   sprinkled per script — and only when `interactive?`.
4. **TTY vs CI detection in one place.** `interactive? = $stdout.tty? && !ENV["CI"]`.
   Everything keys off this; no ad-hoc checks.

## 4. cli-ui capabilities to build on (from the vendored 2.7.0)

- `CLI::UI::Spinner.spin` / `SpinGroup` — `SpinGroup` tasks support
  `update_title`, `set_progress(pct)`, and a `failure_debrief` hook. This is the
  vehicle for both the heartbeat (a long task whose title updates) and
  failure-aware steps.
- `CLI::UI::Progress.progress { |bar| bar.tick(set_percent:) }` — a real bar for
  known-size downloads.
- `CLI::UI::Widgets::Status` — the "working" docked element (`{{@widget/status:…}}`),
  the natural home for a docked heartbeat next to the spinner.
- `CLI::UI::Frame` — grouping.

## 5. Proposed facade: `Dev::UI`

A single module (generalize `Deps::CliUI` up to a top-level `Dev::UI`), with an
injectable backend so it's testable and so CI/plain mode is just another backend.

```
Dev::UI
  .interactive?                      # $stdout.tty? && !ENV["CI"]
  .available?                        # cli-ui loadable
  .enable!                           # idempotent StdoutRouter.enable (interactive only)

  .info/.warn/.success/.fail(msg)    # status lines (glyphs interactive, plain in CI)
  .frame(title) { ... }              # grouping (no-op frame in CI, just a header line)

  .step(title) { ... }               # spinner that PROPAGATES failure (§3.1):
                                     #   interactive -> SpinGroup task, re-raise on error
                                     #   CI/plain    -> "title…" + run block + raise on error

  .task(title) -> Handle             # docked, updatable line for long work:
                                     #   handle.update(text) / handle.progress(pct)
                                     #   interactive -> SpinGroup task (Status widget)
                                     #   CI/plain    -> throttled periodic plain lines

  .download(label, total_bytes:) { |io| ... }
                                     # interactive + known size -> Progress bar
                                     # else -> "downloading label…" + done

  .run(*cmd, chdir: nil)             # inherit TTY (use OUTSIDE steps; e.g. gh progress)
  .capture(*cmd, chdir: nil)         # Open3.capture3 (use INSIDE steps; returns [out,err,status])

  .human_size(bytes)                 # "8.0 GB"
```

Backends:
- `RichBackend` (cli-ui, interactive) — frames, spinners, progress, Status.
- `PlainBackend` (CI/pipe/no-cli-ui) — newline-delimited, ANSI-free, no spinners,
  no progress bar; `task`/heartbeat becomes a throttled "still working (Xs)" line.
- `TestBackend` — records events for assertions (no real IO), à la the DI we use
  in `CredentialAccessor`.

## 6. Migration (phased, each independently shippable)

1. **Introduce `Dev::UI`** + backends + tests. Re-implement `Deps::CliUI` as a
   thin delegator (or alias) so nothing breaks; fix the failure-propagation bug
   here (§3.1) with a regression test.
2. **Host integrations** (`gh`, `steam`, `ficsit`): replace raw `puts` with
   `frame` + `step` + `download` (real sizes from the lockfile). This is the
   `dev up` win the request started from.
3. **`BuildWatcher`**: add the docked heartbeat via `Dev::UI.task` (interactive:
   `working — idle 90s, CPU 180%`; CI: a throttled plain line), keeping the
   existing kill/retry/give-up lines.
4. **`install-build-deps.rb`** and other raw-`puts` spots → facade.
5. **bin scripts** (`setup.rb`, `release.rb`): optional consolidation onto
   `Dev::UI` so router setup lives in one place.

## 7. Testing

- `TestBackend` asserts emitted events (kind + text), no ANSI, no TTY.
- A dedicated test pins §3.1: a `step` whose block raises must re-raise / abort
  (parity between rich and plain backends) — the bug that motivated this.
- Integration tests for `gh`/`steam` keep stubbing the command boundary; assert
  via `TestBackend` that the expected frames/steps fired.

## 8. Open questions (for review)

1. **Naming/placement**: `Dev::UI` (top-level) vs keep everything under
   `Dev::Deps::CliUI`. Leaning top-level since core + watcher are non-deps.
2. **Progress over `gh`**: native `gh` bar (interactive) / quiet+plain (CI), vs a
   unified dev-drawn `Progress` bar that wraps our own chunked download (more
   consistent, but we'd stop shelling `gh release download` and fetch+verify
   ourselves). Recommendation: start with native/quiet; revisit a dev-drawn bar
   if we want byte-accurate progress everywhere.
3. **Heartbeat rendering**: `Widgets::Status` docked element vs a plain
   `SpinGroup` task with `update_title`. Recommendation: `SpinGroup` task
   (simpler) first; adopt `Status` if we want the dedicated docked slot.
4. **bin-script migration**: now (one consistent system) or later (lower risk)?
```
