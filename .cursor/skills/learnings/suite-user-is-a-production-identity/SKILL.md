---
name: suite-user-is-a-production-identity
description: >-
  MUST be used when a test stats a real file's owner, reads
  Etc.getpwuid(Process.uid), or relies on a default identity constant
  (DEFAULT_AGENT_USER, the runner user, a toolchain owner) — the suite
  may be running as that very identity.
---

# The suite's own user can be one of the identities under test

dev's suite runs as whoever the host makes it: `runner` on hosted CI,
`ai-agent` on a cooperative Mac where ai-flow builds, the operator in an
IDE. Those are also the production identities dev's code compares
against (`AgentBootstrap::DEFAULT_AGENT_USER`, `RunnerUser`, a prefix's
stat'd owner). A test that lets a default identity meet a stat'd owner
is asserting on a coincidence: on one host they differ and the "grant"
branch fires; on another they are equal and the "nothing to do" branch
does — a green suite locally, red under the runner.

Wrong — the brew prefix is a tmp dir owned by the suite's user, and the
agent user is left at its default:

    content = Dev::AgentBootstrap.new(runner_user: "human", brew_executable: brew).sudoers_content
    content.include?("ai-agent ALL=(#{owner}) NOPASSWD:SETENV: #{brew}") # false when the suite is ai-agent

Right — name every identity so no two can coincide, and when one must
be the real user (a stat'd owner), say so in the Given:

    Dev::AgentBootstrap.new(agent_user: "ci", runner_user: "human", brew_executable: brew)
    # or: host_identity("svc-runner") — "named so it cannot be this test's own user"

Rule of thumb: an identity read from the process or the filesystem is
the only one allowed to be real; every other identity in the test is a
literal that cannot equal it.

learned-from: dev#365 build pass — two `agent_bootstrap_test.rb` brew-edge
tests failed on the ai-build Mac because the suite ran as `ai-agent`,
the default agent user; the same class was dodged by hand in
`runner_status_test.rb` for hosted CI's `runner` (dev#310).
date: 2026-10-29
