# frozen_string_literal: true

require "dev/cd/repo"
require "dev/cd/workspace"
require "dev/cd/matcher"
require "dev/cd/accessor"
require "dev/cd/shell_hook"

module Dev
  # Global `dev cd` — jump into a local checkout under DEV_CD_ROOT.
  # See Dev::Cd::Accessor for the command surface.
  module Cd
  end
end
