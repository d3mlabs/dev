# frozen_string_literal: true

require "dev/plan/executor"
require "dev/plan/header"
require "dev/plan/settings"
require "dev/plan/github_issues"
require "dev/plan/workspace"
require "dev/plan/merge_base"
require "dev/plan/merge"
require "dev/plan/skill_installer"
require "dev/plan/accessor"

module Dev
  # ai-flow: local Cursor plans as the editing UI for canonical GitHub issues.
  # See `dev plan` (Dev::Plan::Accessor) for the command surface.
  module Plan
  end
end
