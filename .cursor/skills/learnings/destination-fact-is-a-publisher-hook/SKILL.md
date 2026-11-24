---
name: destination-fact-is-a-publisher-hook
description: >-
  MUST be used when a lifecycle verb (release, deploy, package) or the
  composition root is about to branch on a channel's name or a publisher's
  class — `channels.key?("gh")`, `is_a?(GhPublisher)` — or when a new
  channel needs the verbs to behave differently around it.
---

# A destination's fact is a `Publisher` hook, never a channel named in a verb

The lifecycle verbs are identical over every publisher: `release` cuts,
`deploy` moves one head, on any channel alike. What differs per
destination — how it keeps its head (`head_strategy`), what a dry run
reads back (`preview`), whether the forge's latest designation is its
head (`owns_release_designation?`), whether a tree is complete for the
install it runs (`accept!`) — is declared on `Lifecycle::Publisher`
with a default, and the publisher that differs overrides it with the reason
in its comment. A verb or the runner reads the hook over the contributed
publishers; it never knows a channel by name, and a destination fitting no
existing answer is a new hook or strategy value to add first, never a
special case.

Wrong — `release` knows one channel, and the next channel owning a forge
designation is a second name in the check:

    designates_latest: !bindings.channels.key?(Deps::GhPublisher::CHANNEL)

Right — the destination declares the fact, the verb asks every publisher:

    # Lifecycle::Publisher: default false, overridable
    def owns_release_designation? = false
    # Deps::GhPublisher: GitHub's latest designation is this channel's head
    def owns_release_designation? = true
    # Cli::Runner
    designates_latest: bindings.publishers.values.none?(&:owns_release_designation?)

learned-from: dev#665 review (`designates_latest` keyed on the `gh` name → `Publisher#owns_release_designation?`);
dev#661 (`head_strategy`) and dev#676 (`accept!`: `package` asks every channel accepting the build) shaped the same way
date: 2026-11-22
