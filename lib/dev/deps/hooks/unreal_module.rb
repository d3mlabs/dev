# frozen_string_literal: true

module Dev
  module Deps
    module Hooks
      # Post-install hook that generates a thin UnrealBuildTool .Build.cs wrapper
      # around fetched source, making it compilable as a UE module.
      #
      # Usage in dependencies.rb:
      #   cmake "googletest", github: "google/googletest",
      #         tag: "v1.17.0", targets: ["gtest", "gmock"],
      #         post_install: Dev::Deps::Hooks::UnrealModule
      module UnrealModule
        # @param dep  [Dependency] the resolved dependency
        # @param root [Pathname]   project root
        def self.call(dep, root)
          src_dir = root / "build" / "_deps" / "#{dep.name}-src"
          return unless src_dir.directory?

          module_name = to_module_name(dep.name)
          build_cs = src_dir / "#{module_name}.Build.cs"
          return if build_cs.exist?

          File.write(build_cs, generate_build_cs(module_name, dep))
        end

        # Convert a dependency name like "googletest" to a PascalCase UE module name.
        #
        # @param name [String]
        # @return [String]
        def self.to_module_name(name)
          name.gsub(/[^a-zA-Z0-9]/, " ").split.map(&:capitalize).join
        end

        # Generate a .Build.cs that exposes the dep's source as a UE module.
        #
        # @param module_name [String]  PascalCase module name
        # @param dep         [Dependency]
        # @return [String]
        def self.generate_build_cs(module_name, dep)
          public_includes = dep.metadata["public_includes"] || ["."]
          includes_lines = public_includes.map { |inc| "            \"#{inc}\"" }.join(",\n")

          <<~CS
            using UnrealBuildTool;

            public class #{module_name} : ModuleRules
            {
                public #{module_name}(ReadOnlyTargetRules Target) : base(Target)
                {
                    Type = ModuleType.External;
                    PublicIncludePaths.AddRange(new string[] {
            #{includes_lines}
                    });
                }
            }
          CS
        end
      end
    end
  end
end
