# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"
require "dev/project_manifest"
require "dev/project_manifest_loader"
require "fileutils"
require "stringio"
require "tempfile"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ProjectManifestLoaderTest < Minitest::Test
  test "#load returns a manifest with name and ProjectCommand objects from dev.yml" do
    Given "a dev.yml file with name and commands"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
        test:
          run: rspec
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "we get the expected manifest"
    manifest.name == "myproject"
    manifest.commands["up"] == Dev::ProjectCommand.new(run: "./bin/setup.rb", desc: "Setup", repl: false)
    manifest.commands["test"] == Dev::ProjectCommand.new(run: "rspec", desc: "(no description)", repl: false)

    Cleanup
    tmp.close!
  end

  test "#load raises ArgumentError when a command is missing run" do
    Given "a dev.yml file with a command without run"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup but no run
    YAML

    When "loading the manifest"
    build_loader.load(Pathname.new(tmp.path))

    Then "it raises ArgumentError"
    raises ArgumentError

    Cleanup
    tmp.close!
  end

  test "#load with repl flag passes it through to the command" do
    Given "a dev.yml file with repl set"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        console:
          run: ./bin/console
          repl: true
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the command has repl true"
    manifest.commands["console"].repl == true

    Cleanup
    tmp.close!
  end

  test "#load rejects the removed ruby: key at parse time" do
    Given "a dev.yml file still carrying the removed ruby: key"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      ruby: "4.0.1"
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
    YAML

    When "loading the manifest"
    build_loader.load(Pathname.new(tmp.path))

    Then "the stale key is rejected, pointing at the dependencies.rb migration"
    raises Dev::ProjectManifestLoader::UnsupportedDevYamlRubyError

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container config" do
    Given "a dev.yml file with build.container"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    !manifest.build_container.nil?
    manifest.build_container.image == "snappy-linux"
    manifest.build_container.registry == "jpduchesne89"
    manifest.build_container.image_ref == "jpduchesne89/snappy-linux"

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container volumes" do
    Given "a dev.yml file with container volumes"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          volumes:
            - "~/.dev/engines/unreal-engine-css:/ue"
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.volumes == ["~/.dev/engines/unreal-engine-css:/ue"]

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container build_args credential refs" do
    Given "a dev.yml file with container build_args"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          build_args:
            WWISE_EMAIL: wwise/email
            WWISE_PASSWORD: wwise/password
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.build_args == {
      "WWISE_EMAIL" => "wwise/email",
      "WWISE_PASSWORD" => "wwise/password",
    }

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container run_env credential refs" do
    Given "a dev.yml file with container run_env"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          run_env:
            WWISE_TOKEN: wwise/token
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.run_env == { "WWISE_TOKEN" => "wwise/token" }

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container build_secrets credential refs" do
    Given "a dev.yml file with container build_secrets"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          build_secrets:
            WWISE_TOKEN: wwise/token
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.build_secrets == { "WWISE_TOKEN" => "wwise/token" }

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container content_globs" do
    Given "a dev.yml file with container content_globs"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          content_globs:
            - "Mods/*/Source/*/*.Build.cs"
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.content_globs == ["Mods/*/Source/*/*.Build.cs"]

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container structure_globs" do
    Given "a dev.yml file with container structure_globs"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          structure_globs:
            - "Mods/*/Source/*/*.Build.cs"
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.structure_globs == ["Mods/*/Source/*/*.Build.cs"]

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container prewarm command" do
    Given "a dev.yml file with a container prewarm command"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          prewarm: "bash /work/bin/prewarm.sh"
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.prewarm == "bash /work/bin/prewarm.sh"

    Cleanup
    tmp.close!
  end

  test "#load defaults build.container prewarm to nil" do
    Given "a dev.yml file without a prewarm command"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.prewarm.nil?

    Cleanup
    tmp.close!
  end

  test "#load defaults build.container build_secrets, content_globs and structure_globs to empty" do
    Given "a dev.yml file without build_secrets, content_globs or structure_globs"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.build_secrets == {}
    manifest.build_container.content_globs == []
    manifest.build_container.structure_globs == []

    Cleanup
    tmp.close!
  end

  test "#load defaults build.container volumes to empty" do
    Given "a dev.yml file without container volumes"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.volumes == []

    Cleanup
    tmp.close!
  end

  test "#load extracts build.container persist flag" do
    Given "a dev.yml file with persist: true"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          persist: true
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.persist == true

    Cleanup
    tmp.close!
  end

  test "#load defaults build.container persist to false" do
    Given "a dev.yml file without persist"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.persist == false

    Cleanup
    tmp.close!
  end

  test "#load returns nil build_container when not declared" do
    Given "a dev.yml without build.container"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        up:
          run: ./bin/setup.rb
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.build_container.nil?

    Cleanup
    tmp.close!
  end

  test "#load extracts a runner block with string labels" do
    Given "a dev.yml file with a runner block"
    tmp = write_dev_yml(<<~YAML)
      name: unreal-engine
      runner:
        labels: ue-engine
        dir: "~/actions-runner-ue"
        name: gaming-box
        version: "2.335.1"
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.runner == Dev::RunnerSetupConfig.new(
      labels: "ue-engine", dir: "~/actions-runner-ue", name: "gaming-box", version: "2.335.1",
    )

    Cleanup
    tmp.close!
  end

  test "#load normalizes a runner labels list to comma-separated" do
    Given "a dev.yml file with a runner labels list"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      runner:
        labels:
          - snappy
          - x64
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.runner.labels == "snappy,x64"
    manifest.runner.dir.nil?

    Cleanup
    tmp.close!
  end

  test "#load selects the current host's identity from a host-keyed runner block" do
    Given "a dev.yml with one runner identity per host OS"
    tmp = write_dev_yml(<<~YAML)
      name: unreal-engine
      runner:
        linux:
          labels: ue-engine
        darwin:
          labels:
            - macos
            - ue-editor
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the identity matches the OS the test is running on"
    expected_labels = RUBY_PLATFORM.include?("darwin") ? "macos,ue-editor" : "ue-engine"
    manifest.runner.labels == expected_labels

    Cleanup
    tmp.close!
  end

  test "#load returns nil runner when a host-keyed block has no entry for this host" do
    Given "a dev.yml keyed only for the other host OS"
    other_host = RUBY_PLATFORM.include?("darwin") ? "linux" : "darwin"
    tmp = write_dev_yml(<<~YAML)
      name: unreal-engine
      runner:
        #{other_host}:
          labels: ue-engine
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "this host has no runner identity"
    manifest.runner.nil?

    Cleanup
    tmp.close!
  end

  test "#load returns nil runner when not declared" do
    Given "a dev.yml without a runner block"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        up:
          run: ./bin/setup.rb
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.runner.nil?

    Cleanup
    tmp.close!
  end

  test "#load returns nil runner when labels are absent" do
    Given "a dev.yml with a labelless runner block"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      runner:
        dir: "~/actions-runner"
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.runner.nil?

    Cleanup
    tmp.close!
  end

  test "#load handles container: false on individual commands" do
    Given "a dev.yml with container opt-out on a command"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
        deploy:
          run: ./bin/deploy.sh
          container: false
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.commands["build"].container == true
    manifest.commands["deploy"].container == false

    Cleanup
    tmp.close!
  end

  test "#load leaves the toolchain fields nil (the dependencies.rb pass is separate)" do
    Given "a plain dev.yml"
    tmp = write_dev_yml("name: myproject\n")

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "no toolchain is declared yet"
    manifest.declared_ruby_version.nil?
    manifest.declared_python_version.nil?

    Cleanup
    tmp.close!
  end

  test "#with_toolchain reads the dependencies.rb ruby directive" do
    Given "a project whose dependencies.rb declares ruby"
    root = Pathname.new(Dir.mktmpdir("loader-ruby-deps-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { ruby "9.9.9" }
    RUBY

    When "the toolchain pass runs"
    manifest = build_loader.with_toolchain(bare_manifest, project_root: root)

    Then "the dependencies.rb directive is used"
    manifest.declared_ruby_version == "9.9.9"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "#with_toolchain reads the dependencies.rb python directive" do
    Given "a project whose dependencies.rb declares python"
    root = Pathname.new(Dir.mktmpdir("loader-python-deps-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { python "3.12" }
    RUBY

    When "the toolchain pass runs"
    manifest = build_loader.with_toolchain(bare_manifest, project_root: root)

    Then "the dependencies.rb directive is used"
    manifest.declared_python_version == "3.12"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "#with_toolchain ignores a config left over from a previously loaded manifest" do
    Given "a stale config from an earlier manifest load, and a project whose dependencies.rb never calls Dev::Deps.define (bootstrap constants)"
    Dev::Deps.define { ruby "9.9.9" }
    root = Pathname.new(Dir.mktmpdir("loader-ruby-stale-"))
    File.write(root / "dependencies.rb", "SOME_CONSTANT = 1 unless defined?(SOME_CONSTANT)\n")

    When "the toolchain pass runs"
    manifest = build_loader.with_toolchain(bare_manifest, project_root: root)

    Then "the stale config is not mistaken for this project's declaration"
    manifest.declared_ruby_version.nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "#with_toolchain declares nothing when there is no deps manifest (Homebrew fallback)" do
    Given "a project with no dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("loader-ruby-fallback-"))

    When "the toolchain pass runs"
    manifest = build_loader.with_toolchain(bare_manifest, project_root: root)

    Then "nothing is declared, so resolve_ruby_version will fall back to Homebrew Ruby"
    manifest.declared_ruby_version.nil?
    manifest.declared_python_version.nil?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "#with_toolchain warns and declares nothing for a broken dependencies.rb" do
    Given "a project whose dependencies.rb raises on load"
    root = Pathname.new(Dir.mktmpdir("loader-ruby-broken-"))
    File.write(root / "dependencies.rb", "raise 'kaboom'\n")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "the toolchain pass runs"
    manifest = build_loader.with_toolchain(bare_manifest, project_root: root)

    Then "the failure is reported and the toolchain falls back like an undeclared one"
    $stderr.string.include?("could not read the toolchain")
    $stderr.string.include?("kaboom")
    manifest.declared_ruby_version.nil?

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "#with_toolchain preserves the dev.yml side of the manifest" do
    Given "a manifest with commands and a project declaring ruby"
    root = Pathname.new(Dir.mktmpdir("loader-preserve-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { ruby "9.9.9" }
    RUBY
    project_command = Dev::ProjectCommand.new(run: "rspec", desc: "Run tests")
    manifest = Dev::ProjectManifest.new(name: "myproject", commands: { "test" => project_command })

    When "the toolchain pass runs"
    completed = build_loader.with_toolchain(manifest, project_root: root)

    Then "name and commands ride along unchanged"
    completed.name == "myproject"
    completed.commands == { "test" => project_command }
    completed.declared_ruby_version == "9.9.9"

    Cleanup
    FileUtils.rm_rf(root)
  end

  private

  def build_loader
    Dev::ProjectManifestLoader.new(command_parser: Dev::CommandParser.new)
  end

  def bare_manifest
    Dev::ProjectManifest.new(name: "myproject", commands: {})
  end

  def write_dev_yml(content)
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(content)
    tmp.flush
    tmp
  end
end
