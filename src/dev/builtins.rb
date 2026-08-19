# typed: strict
# frozen_string_literal: true

module Dev
  # One class per builtin dev command, each subclassing BuiltinCommand —
  # the sealed Command hierarchy's declared open edge — with its
  # collaborators constructor-injected; per-call values stay method-side.
  # The composition root (Runner) decides which builtins exist for a given
  # project (config-gated: runner-setup only with a `runner:` block,
  # provide-image/reset-container only with a build container).
  module Builtins; end
end

require_relative "builtins/cache_command"
require_relative "builtins/cd_command"
require_relative "builtins/check_command"
require_relative "builtins/clone_command"
require_relative "builtins/cred_command"
require_relative "builtins/deps_command"
require_relative "builtins/help_command"
require_relative "builtins/install_deps_command"
require_relative "builtins/learnings_command"
require_relative "builtins/plan_command"
require_relative "builtins/provide_image_command"
require_relative "builtins/reset_container_command"
require_relative "builtins/runner_setup_command"
require_relative "builtins/up_command"
require_relative "builtins/update_deps_command"
