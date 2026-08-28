# frozen_string_literal: true

require "dev/settings"
require "dev/host_service"
require "dev/plan/executor"
require "dev/plan/header"
require "dev/plan/frontmatter"
require "dev/plan/content"
require "dev/plan/github_issues"
require "dev/plan/workspace"
require "dev/plan/templates"
require "dev/plan/merge_base"
require "dev/plan/merge"
require "dev/plan/accessor"

module Dev
  # ai-flow: local Cursor plans as the editing UI for canonical GitHub issues.
  # See `dev plan` (Dev::Plan::Accessor) for the command surface.
  module Plan
  end
end
