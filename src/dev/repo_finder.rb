# frozen_string_literal: true

module Dev
  # Locates the repository root by walking up from a directory until dev.yml is found.
  class RepoFinder
    FILENAME = "dev.yml"

    def self.find(start_dir = Dir.pwd)
      new(start_dir).find
    end

    def initialize(start_dir)
      @start_dir = File.expand_path(start_dir)
    end

    def find
      d = @start_dir
      while d && d != "/"
        return d if File.file?(File.join(d, FILENAME))
        d = File.dirname(d)
      end
      nil
    end
  end
end
