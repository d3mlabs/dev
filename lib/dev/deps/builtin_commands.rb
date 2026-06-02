# frozen_string_literal: true

require_relative "locker"
require_relative "dependency"

module Dev
  module Deps
    # Built-in command handlers for dependency management.
    #
    # `update-deps`:  resolve constraints → write lockfiles
    # `up` pre-step:  read lockfiles → install all deps (build first)
    #
    # Runner checks BuiltinCommands.builtin? before YAML lookup. If a project
    # defines the same command name, the project command runs after the built-in.
    module BuiltinCommands
      BUILTIN_COMMANDS = %w[update-deps].freeze

      def self.builtin?(command_name)
        BUILTIN_COMMANDS.include?(command_name)
      end

      # Read dependencies from both lockfiles, grouped by integration type.
      # Used by dev up to install all deps.
      #
      # @param root [String] project root directory
      # @return [Hash{Symbol => Array<Dependency>}] integration type → deps
      def self.read_lockfile_deps(root:)
        locker = Locker.new
        app_deps = locker.read(lockfile_path: File.join(root, Locker::DEPS_LOCK))
        build_deps = locker.read(lockfile_path: File.join(root, Locker::BUILD_DEPS_LOCK))

        all_deps = build_deps + app_deps
        all_deps.group_by(&:integration)
      end

      # Run the update-deps built-in: resolve constraints → write lockfiles.
      #
      # @param root         [String] project root
      # @param repositories [Hash{Symbol => Repository}] integration type → repository
      def self.update_deps(root:, repositories:)
        require_relative "resolver"
        require_relative "config"

        deps_rb = File.join(root, "dependencies.rb")
        load(deps_rb) if File.exist?(deps_rb)

        declared = build_dep_list_from_config
        resolver = Resolver.new(repositories: repositories)
        resolved = resolver.resolve(declared)

        locker = Locker.new
        locker.write_for_groups(resolved, root: root)
      end

      # Install all deps from lockfiles. Build group first, then app + test.
      #
      # @param root         [String] project root
      # @param integrations [Hash{Symbol => Integration}] registered integrations
      def self.install_all(root:, integrations:)
        grouped = read_lockfile_deps(root: root)

        grouped.each do |integration_type, deps|
          build_deps = deps.select { |d| d.group == :build }
          next if build_deps.empty?
          integration = integrations[integration_type]
          integration&.install_all(build_deps, root: root)
        end

        grouped.each do |integration_type, deps|
          runtime_deps = deps.reject { |d| d.group == :build }
          next if runtime_deps.empty?
          integration = integrations[integration_type]
          integration&.install_all(runtime_deps, root: root)
        end
      end

      class << self
        private

        def build_dep_list_from_config
          deps = []
          %w[app test build].each do |group_name|
            group = Config.group(group_name)
            (group["runtime"] || []).each do |dep_spec|
              dep_spec.each do |name, spec|
                next unless spec.is_a?(Hash)
                integration = (spec["integration"] || "cmake").to_sym
                deps << {
                  name: name,
                  integration: integration,
                  constraint: spec,
                  group: group_name.to_sym,
                }
              end
            end
          end
          deps
        end
      end
    end
  end
end
