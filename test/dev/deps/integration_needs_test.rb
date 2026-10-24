# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/integration_needs"
require "dev/deps/registry"
require "dev/deps/xcode_integration"
require "dev/deps/wwise_integration"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::IntegrationNeedsTest < Minitest::Test
  # Define an Integration subclass from a file in dir, with an optional
  # sibling dependencies.rb, the way a project-local `register`ed
  # integration ships. The class file is evaluated under its own path so
  # the class's source location — what the manifest convention reads — is
  # that file; the file's last expression hands the class back.
  def define_integration(dir, class_name, manifest: nil)
    file_stem = class_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    class_file = dir / "#{file_stem}.rb"
    class_file.write(<<~RUBY)
      require "dev/deps/integration"
      class #{class_name} < Dev::Deps::Integration; end
      #{class_name}
    RUBY
    if manifest
      (dir / file_stem).mkpath
      (dir / file_stem / "dependencies.rb").write(manifest)
    end
    Object.class_eval(class_file.read, class_file.to_s, 1)
  end

  test "table reads each integration's manifest exports under its symbol; integrations without one are absent" do
    Given "one integration with a manifest and one without"
    dir = Pathname(Dir.mktmpdir("dev-needs-test-"))
    with_manifest = define_integration(dir, "NeedsTestToolIntegration", manifest: <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "tool-cli", tap: "acme/tools"
        group :build do
          brew "private-helper"
        end
      end
    RUBY
    without = define_integration(dir, "NeedsTestBareIntegration")

    When "building the table"
    table = Dev::Deps::IntegrationNeeds.new.table({ tool: with_manifest, bare: without })

    Then "only the manifest's ungrouped line is a need, keyed by the integration symbol"
    table.keys == [:tool]
    table[:tool].map(&:name) == ["tool-cli"]
    table[:tool][0].integration == :brew
    table[:tool][0].source == "acme/tools"

    Cleanup
    Object.send(:remove_const, :NeedsTestToolIntegration)
    Object.send(:remove_const, :NeedsTestBareIntegration)
    FileUtils.rm_rf(dir)
  end

  test "table refuses a manifest that needs a pin of its own integration type" do
    Given "an integration whose manifest declares through its own verb"
    dir = Pathname(Dir.mktmpdir("dev-needs-test-"))
    klass = define_integration(dir, "NeedsTestSelfIntegration", manifest: <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { custom "myself", integration: :selfish }
    RUBY

    When "building the table"
    error = assert_raises(Dev::Deps::IntegrationNeeds::SelfNeedError) do
      Dev::Deps::IntegrationNeeds.new.table({ selfish: klass })
    end

    Then
    error.message.include?("myself")
    error.message.include?("selfish")

    Cleanup
    Object.send(:remove_const, :NeedsTestSelfIntegration)
    FileUtils.rm_rf(dir)
  end

  test "table leaves the project's own config untouched — a library read never masquerades as the project" do
    Given "a project config already defined, and an integration with a manifest"
    project_config = Dev::Deps.define { ruby "4.0.1" }
    dir = Pathname(Dir.mktmpdir("dev-needs-test-"))
    klass = define_integration(dir, "NeedsTestQuietIntegration", manifest: <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { brew "quiet-cli" }
    RUBY

    When "building the table"
    Dev::Deps::IntegrationNeeds.new.table({ quiet: klass })

    Then
    Dev::Deps.last_config.equal?(project_config)

    Cleanup
    Object.send(:remove_const, :NeedsTestQuietIntegration)
    FileUtils.rm_rf(dir)
  end

  test "the built-in #{symbol} integration needs exactly its CLI formula, exported by its own manifest" do
    Given "the registry's wired integration classes"
    classes = Dev::Deps::Registry.integration_classes

    When "building the table"
    table = Dev::Deps::IntegrationNeeds.new.table(classes)

    Then "one brew need, with the expected tap"
    needs = table.fetch(symbol)
    needs.map(&:name) == [formula]
    needs[0].integration == :brew
    needs[0].source == tap
    needs[0].scope.host == host

    Where
    symbol | formula     | tap               | host
    :xcode | "xcodes"    | nil               | :darwin
    :wwise | "wwise-cli" | "d3mlabs/d3mlabs" | nil
  end

  test "built-in integrations other than xcode and wwise carry no manifest today" do
    Given "the registry's wired integration classes"
    table = Dev::Deps::IntegrationNeeds.new.table(Dev::Deps::Registry.integration_classes)

    Expect
    table.keys.sort == [:wwise, :xcode]
  end
end
