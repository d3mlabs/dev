# typed: strict
# frozen_string_literal: true

require "dev/skills/layout"
require "dev/skills/channel"
require "dev/skills/installer"
require "dev/skills/materializer"
require "dev/skills/corpus_channel"
require "dev/skills/accessor"

module Dev
  # Skill materialization: the one place dev places agent skills into their
  # discovery roots. Producers — dev's own shipped set, the org knowledge
  # corpus (Learnings), the locked gem set (Deps) — describe what they have
  # as a Channel; the Materializer links each channel into its root and
  # prunes what the channel stopped declaring. `Dev::Skills` never learns a
  # producer's vocabulary (gems, caches); producers never touch a symlink.
  module Skills
  end
end
