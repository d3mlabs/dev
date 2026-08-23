# frozen_string_literal: true

# The host baseline manifest (plans#26, layer 1 of a machine): the
# org-invariant tools every d3mlabs host converges toward, regardless of
# which projects it serves. Shipped inside dev's distribution — upgrading
# dev is what changes the baseline. `dev up` converges it as its first
# step; every other command only warns when it drifts.
#
# Everything here is a Homebrew name and brew converges by name, so there
# is no lockfile — the baseline declares a tool set, not versions.
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

  # Deliberately NOT here: the Cursor agent CLI. It is ai-flow's own
  # dependency (declared in ai-flow's dependencies.rb as the cursor-cli
  # cask) — converging the ai-flow checkout is what makes a box
  # agent-capable, so target hosts and plain dev machines never carry
  # agent pieces they don't serve.
end
