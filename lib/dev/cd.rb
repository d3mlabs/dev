# frozen_string_literal: true

require "dev/cd/repo"
require "dev/cd/repo_discovery"
require "dev/cd/matcher"
require "dev/cd/hook_installer"
require "dev/cd/accessor"

module Dev
  # `dev cd`: jump to a local checkout under $DEV_CD_ROOT (default ~/src) by
  # short name, with segmented fuzzy matching and shell-side Tab completion.
  # See Dev::Cd::Accessor for the command surface.
  module Cd
  end
end
