---
name: verb-follows-the-data
description: >-
  MUST be used when a lifecycle verb composes another verb that may
  dispatch (runs `package`, `build` or `deploy` through the executor) and
  then reads something from this machine — the store, a file the child
  wrote — or when a verb fails only under a remote placement.
---

# A verb follows the data: a stage runs where its input is, only facts cross back

A composed verb (`package`, `build`, `deploy <channel>`) resolves its own
dispatch, so after it returns nothing it produced is known to be on this
machine: the artifact is in the store of the host that packaged (K10).
A parent verb that reads the local store afterwards works only while
every child ran natively, and fails exactly under the placements the
dispatch exists for (a host-placed linux64 from a Mac, a runner-only
environment). Split the parent by where each stage's input is: what is
the checkout's (git state, the operator's confirm) stays local; what
needs the built tree is one unit the child carries to its host, as a
flag on the child's verb (`package <build> --attach <version>`); and
what crosses back is a fact read from the destination (the forge's
assets, a ledger the child wrote there), never the bytes. Bringing the
bytes back (`--fetch` per child) is the round trip, not the fix.

Wrong — the parent assumes the child's output is here:

    @executor.execute(@package, args: [build.name], context:)
    artifact = @store.artifact(build)        # nil when the child dispatched
    raise ArtifactNotAtTagError unless artifact&.current?(at_tag)

Right — the child carries the stage to its host, the parent reads the destination:

    @executor.execute(@package, args: [build.name, "--attach", tag.version], context:)
    # after every child: the forge's facts, the same whether any ran here
    entries = @ledger.read(tag)&.archives; assets = @releases.asset_names(tag)

learned-from: dev#744 (`release` read the artifact back from the local store after `dev package`, which dispatches;
a dispatched build never reached it → `package --attach` on the packaging host, a `release.json` ledger the local side verifies)
date: 2026-11-28
