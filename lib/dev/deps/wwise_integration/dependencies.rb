# typed: false
# frozen_string_literal: true

# The wwise integration's own manifest: the tooling WwiseIntegration shells
# to, in the same DSL a project uses. Ungrouped, so it exports: a project
# that pins a Wwise SDK gets these locked into its own deps.lock with
# provenance (needed_by: wwise), in the scope of its wwise declaration, and
# installed before the wwise batch (ADR-0011).
require "dev/deps"

Dev::Deps.define do
  # The downloader that fills the SDK cache (https://github.com/d3mlabs/wwise-cli).
  brew "wwise-cli", tap: "d3mlabs/d3mlabs"
end
