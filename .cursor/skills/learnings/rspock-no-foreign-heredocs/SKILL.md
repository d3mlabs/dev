---
name: rspock-no-foreign-heredocs
description: >-
  MUST be used when a test in a transform!(RSpock::AST::Transformation)
  class needs a block of non-Ruby text (a shell program, a config file,
  a script preamble), or when `dev test` on one file sits CPU-bound with
  no output and no child process.
---

# No foreign-language heredocs inside a transform!-ed test class

RSpock re-emits the whole file through ast_transform's unparser, and a
heredoc holding shell text (`$(…)`, `\"` escapes, interpolation) either
raises `Unparser::UnsupportedNodeError: s(:dstr …)` or spins forever at
load — `dev test <file>` then shows the rake banner and nothing else,
with the ruby process in state R and no children. Keep such text in a
real file under `test/support/` (or `test/fixtures/`), parametrised by
environment variables, and `read` it from the test.

Wrong — a shell stub preamble as a heredoc in a private helper of the
test class (hangs the suite before the first test runs):

    def stubbed_tools(tap_dir:)
      <<~SH
        brew() { echo "$* $(ls -ld "$HOME/.homebrew")"; ... }
      SH
    end

Right — `test/support/container_provision_stubs.sh` read as text, its
inputs passed as env to `Open3.capture3`; a `.sh` file also gets
shellcheck and syntax highlighting the heredoc never had.

Root cause lives in ast_transform (line-aligned emission of `dstr`
nodes), not here; a heredoc of plain prose (no `$(`, no escaped quotes)
still works, but the file is the safer, more readable home regardless.

learned-from: dev#406 build pass — a shell-stub heredoc hung `dev test`
on one file for minutes; bisected to the helper, moved to test/support/.
date: 2026-11-02
