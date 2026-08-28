# typed: strict
# frozen_string_literal: true

require "dev/clone/repo_spec"
require "dev/clone/gh_cloner"
require "dev/clone/accessor"

module Dev
  # `dev clone`: clone a GitHub repo via the user's gh auth into the canonical
  # checkout layout under $DEV_CD_ROOT (default ~/src), landing the shell in
  # the fresh checkout through the same wrapper that powers `dev cd`. See
  # Dev::Clone::Accessor for the command surface.
  module Clone
  end
end
