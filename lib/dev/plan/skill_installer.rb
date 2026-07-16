# frozen_string_literal: true

require "fileutils"

module Dev
  module Plan
    # Ensures ~/.cursor/skills/ai-flow is a symlink to the skill shipped inside
    # dev's package (share/cursor-skills/ai-flow). Called at the start of every
    # `dev plan` invocation: cheap and idempotent, so there is no separate
    # setup step and `brew upgrade` refreshes the skill automatically (the
    # symlink resolves through the installed tree, wherever brew put it).
    class SkillInstaller
      SKILL_NAME = "ai-flow"

      # @param skill_source [String, nil] override for tests; defaults to the
      #   skill directory inside this dev installation
      # @param skills_dir [String, nil] override for tests; defaults to
      #   ~/.cursor/skills
      def initialize(skill_source: nil, skills_dir: nil)
        @skill_source = skill_source || default_skill_source
        @skills_dir = skills_dir || File.join(Dir.home, ".cursor", "skills")
      end

      # Install or refresh the symlink. Never raises: a broken skill install
      # must not block a sync command (the failure is reported on stderr).
      #
      # @return [void]
      def ensure_installed
        return unless File.directory?(@skill_source)

        link = File.join(@skills_dir, SKILL_NAME)
        return if File.symlink?(link) && File.readlink(link) == @skill_source

        if File.exist?(link) && !File.symlink?(link)
          $stderr.puts "dev: warning: #{link} exists and is not a symlink — leaving it in place."
          return
        end

        FileUtils.mkdir_p(@skills_dir)
        FileUtils.rm_f(link)
        File.symlink(@skill_source, link)
      rescue SystemCallError => e
        $stderr.puts "dev: warning: could not install the ai-flow skill symlink (#{e.message})."
      end

      private

      # share/cursor-skills/ai-flow relative to this file (lib/dev/plan/ →
      # repo or libexec root), which is the installed location under brew.
      #
      # @return [String]
      def default_skill_source
        File.expand_path(File.join(__dir__, "..", "..", "..", "share", "cursor-skills", SKILL_NAME))
      end
    end
  end
end
