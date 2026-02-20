# frozen_string_literal: true

# Dev CLI: find repo with dev.yml, run declared commands (optionally in a CLI::UI Frame).
# Entry point: Dev::Runner.run(ARGV)
module Dev
end

require_relative "dev/config"
require_relative "dev/repo_finder"
require_relative "dev/config_loader"
require_relative "dev/cli_ui"
require_relative "dev/command_runner"
require_relative "dev/usage"
require_relative "dev/runner"
