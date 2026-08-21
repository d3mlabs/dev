# frozen_string_literal: true

# The host baseline manifest (plans#26, layer 1 of a machine): the
# org-invariant tools every d3mlabs host converges toward, regardless of
# which projects it serves. Shipped inside dev's distribution — upgrading
# dev is what changes the baseline — with the lock committed next to this
# file (regenerate via bin/update-baseline.rb). `dev up` converges it as
# its first step; every other command only warns when it drifts.
#
# Deliberately small: project-specific tools belong in each repo's
# dependencies.rb (layer 2), and OS-provided tools (curl, tar) are not
# re-declared — shadowing the system copies buys nothing.
require "dev/deps"

Dev::Deps.define do
  group :baseline do
    # Declared even though dev's Homebrew formula pulls git/gh via
    # depends_on — the manifest is the verification record, and hosts that
    # got dev some other way still converge.
    brew "git"
    brew "gh"
    # dev's Ruby toolchain managers: project rubies via rbenv, per-project
    # activation via shadowenv.
    brew "rbenv"
    brew "shadowenv"
  end

  # The headless Cursor agent CLI ai-flow spawns. darwin-gated: agent jobs
  # route to Mac runners; target hosts (the gamebox) never get agent pieces.
  group :agent, host: :darwin do
    cursor_agent "cursor-agent", install_dir: "~/.dev/tools/cursor-agent"
  end
end
