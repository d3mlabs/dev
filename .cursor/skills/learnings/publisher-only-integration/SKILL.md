---
name: publisher-only-integration
description: >-
  MUST be used when adding a built-in publisher (a `deploy <channel>` the
  lock contributes) for a store the project has no reason to *read* from —
  a storefront, a launcher, a mod portal reached only by its upload tool.
---

# A store with no read side gets its channel by pinning its upload tool

A channel is contributed by the lock, never named in dev.yml (ADR-0010:
the verb follows the channel). That needs a dependency to pin — easy when
the store is also something the project consumes (`steam "App"` pins a
depot, and `SteamRepository` is both read and write side, one client),
impossible when nothing is ever read from it. The answer is to make the
**tool that publishes to it** the dependency: a url-shaped universe
(`UrlRepository` — the download is the whole address, TOFU-hashed at
`dev deps update`) under the integration's own symbol, installed by its
own integration as a store tree keyed by the locked digest, so `dev up`
provisions the tool and the pin is what makes `deploy <channel>` exist.
The publisher is then a class of its own (the read side's client is
curl; the write side's is the tool), and finds the binary through the
lock and the store exactly as `dev deps path <channel> <name>` does.

Wrong — a channel with nothing to pin, so dev.yml would have to name it:

    Entry.new(symbol: :egs, repository: nil, integration: nil, publisher: EgsPublisher)

Right — the tool is the dependency; pinning it contributes the channel:

    egs "BuildPatchTool"                      # dependencies.rb
    Entry.new(symbol: :egs, repository: UrlRepository, scheme: nil,
      integration: EgsIntegration, publisher: EgsPublisher, publisher_needs: %i[project_root])

The publisher is the repository class when read and write share one
client and auth (steamcmd), a separate `<Store>Publisher` otherwise.

learned-from: dev#426 (the `steam` and `egs` built-in publishers): egs
had no read side; the sibling publishers (dev#427–#429) face the same.
date: 2026-11-08
