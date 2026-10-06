# typed: strict
# frozen_string_literal: true

module Dev
  # One class per builtin, each subclassing BuiltinCommand — the sealed
  # Command hierarchy's declared open edge — with its collaborators
  # constructor-injected; per-call values stay method-side. Nouns with
  # verbs are CommandGroups declared in a composition root over these
  # leaves: `deps`, `cache`, `container`, `runner` in the Runner (which
  # also decides which builtins exist for a given project — config-gated:
  # `container` only with a build container), the global nouns (`config`,
  # `cred`, `engine`, `learnings`, `plan`) in GlobalCatalog. A builtin
  # heads a subtree of its own via `children:` / `with_children`.
  module Builtins; end
end

require_relative "builtins/cache_gc_command"
require_relative "builtins/cd_command"
require_relative "builtins/check_command"
require_relative "builtins/clone_command"
require_relative "builtins/complete_command"
require_relative "builtins/config_get_command"
require_relative "builtins/config_list_command"
require_relative "builtins/config_set_command"
require_relative "builtins/container_down_command"
require_relative "builtins/container_reset_command"
require_relative "builtins/container_status_command"
require_relative "builtins/container_tag_command"
require_relative "builtins/container_up_command"
require_relative "builtins/cred_get_command"
require_relative "builtins/deps_path_command"
require_relative "builtins/down_command"
require_relative "builtins/engine_down_command"
require_relative "builtins/engine_status_command"
require_relative "builtins/engine_up_command"
require_relative "builtins/help_command"
require_relative "builtins/install_deps_command"
require_relative "builtins/learnings_init_command"
require_relative "builtins/learnings_invariants_command"
require_relative "builtins/learnings_status_command"
require_relative "builtins/learnings_sync_command"
require_relative "builtins/plan_hook_after_edit_command"
require_relative "builtins/plan_init_command"
require_relative "builtins/plan_link_command"
require_relative "builtins/plan_new_command"
require_relative "builtins/plan_pull_command"
require_relative "builtins/plan_push_command"
require_relative "builtins/plan_status_command"
require_relative "builtins/runner_register_command"
require_relative "builtins/runner_status_command"
require_relative "builtins/runner_unregister_command"
require_relative "builtins/service_down"
require_relative "builtins/service_up"
require_relative "builtins/up_command"
require_relative "builtins/update_deps_command"
