# frozen_string_literal: true

module Dev
  # Locates the project root: git root when it contains dev.yml. We expect dev.yml at project root only.
  class RepoFinder
    FILENAME = "dev.yml"

    def initialize(start_dir = Dir.pwd)
      @start_dir = File.expand_path(start_dir)
    end

    def find
      root = git_root
      return root if root && File.file?(File.join(root, FILENAME))
      nil
    end

    private

    def git_root
      Dir.chdir(@start_dir) do
        out = `git rev-parse --show-toplevel 2>/dev/null`.strip
        out.empty? ? nil : File.expand_path(out)
      end
    rescue Errno::ENOENT
      nil
    end
  end
end
