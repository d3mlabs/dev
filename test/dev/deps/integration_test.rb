# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/integration"
require "dev/deps/repository"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::IntegrationTest < Minitest::Test
  test "base class install_all raises NotImplementedError" do
    Given "an Integration with injected dependencies"
    repo = Dev::Deps::Repository.new
    integration = Dev::Deps::Integration.new(repository: repo, store: nil)

    When "calling install_all"
    integration.install_all([])

    Then
    raises NotImplementedError
  end

  test "base class tree_key raises NotImplementedError: an integration without a tree places nothing" do
    Given "a locked dep and the base Integration"
    dep = Dev::Deps::Dependency.new(
      name: "x", integration: :none, group: :app, version: "1", hash: nil, metadata: {},
    )

    When "asking the base class where its tree is"
    error = assert_raises(NotImplementedError) { Dev::Deps::Integration.tree_key(dep) }

    Then "it says the integration installs no tree"
    error.message.include?("installs no tree")
  end

  # Define an Integration subclass from a class file in dir, evaluated under
  # its own path so the class's source location — what the manifest
  # convention reads — is that file; the file's last expression hands the
  # class back.
  def define_integration_in(dir, file_stem, class_name)
    class_file = dir / "#{file_stem}.rb"
    class_file.write(<<~RUBY)
      require "dev/deps/integration"
      class #{class_name} < Dev::Deps::Integration; end
      #{class_name}
    RUBY
    Object.class_eval(class_file.read, class_file.to_s, 1)
  end

  test "manifest_path follows the file convention: <class file sans .rb>/dependencies.rb" do
    Given "an integration class defined in a file, with a sibling manifest directory"
    dir = Pathname(Dir.mktmpdir("dev-integration-manifest-"))
    klass = define_integration_in(dir, "acme_integration", "AcmeManifestedIntegration")
    (dir / "acme_integration").mkpath
    (dir / "acme_integration" / "dependencies.rb").write("Dev::Deps.define { brew \"acme-cli\" }\n")

    When "asking for its manifest"
    manifest = klass.manifest_path

    Then "the sibling file is found"
    manifest == dir / "acme_integration" / "dependencies.rb"

    Cleanup
    Object.send(:remove_const, :AcmeManifestedIntegration)
    FileUtils.rm_rf(dir)
  end

  test "manifest_path is nil for an integration without a manifest — it needs no tooling of its own" do
    Given "an integration class defined in a file with no sibling manifest"
    dir = Pathname(Dir.mktmpdir("dev-integration-manifest-"))
    klass = define_integration_in(dir, "bare_integration", "BareUnmanifestedIntegration")

    Expect
    klass.manifest_path.nil?

    Cleanup
    Object.send(:remove_const, :BareUnmanifestedIntegration)
    FileUtils.rm_rf(dir)
  end

  test "manifest_path is nil for an anonymous integration class — no file, no convention" do
    Given "a class with no name"
    klass = Class.new(Dev::Deps::Integration)

    Expect
    klass.manifest_path.nil?
  end

  test "an integration is not the host prerequisite unless it says so" do
    Expect "the base default"
    Dev::Deps::Integration.host_prerequisite? == false
  end
end
