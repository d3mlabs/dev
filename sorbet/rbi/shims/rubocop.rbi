# typed: true

# RuboCop's RBIs are not generated (tapioca excludes the gem: Ruby 4 breaks
# yard's legacy parser on it, sorbet/tapioca/config.yml). The gate's own cop
# (rubocop/cop/dev/shell_reference.rb) and its test are the only typed-false
# code that names RuboCop, and these are the constants they name.
module RuboCop
  class Config
    def initialize(hash = T.unsafe(nil), loaded_path = T.unsafe(nil)); end
    def base_dir_for_path_parameters; end
  end

  class ProcessedSource
    def initialize(source, ruby_version, path = T.unsafe(nil)); end
    def file_path; end
  end

  module Cop
    class Base
      def self.def_node_matcher(method_name, pattern_str); end
      def add_offense(node_or_range, message: T.unsafe(nil), severity: T.unsafe(nil), &block); end
      def processed_source; end
      def config; end
    end

    class Commissioner
      def initialize(cops, forces = T.unsafe(nil), options = T.unsafe(nil)); end
      def investigate(processed_source, offset: T.unsafe(nil), original: T.unsafe(nil)); end
    end
  end
end
