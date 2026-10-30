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

  test "#load parses nested commands into the entry's children" do
    Given "a dev.yml with a runnable test command that nests a unit command"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        test:
          desc: Test suites
          run: ./bin/test.sh
          commands:
            unit:
              run: rspec spec/unit
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the tree is the parsed command heading its children"
    manifest.commands["test"] == Dev::ProjectCommand.new(
      run: "./bin/test.sh",
      desc: "Test suites",
      children: { "unit" => Dev::ProjectCommand.new(run: "rspec spec/unit") },
    )

    Cleanup
    tmp.close!
  end

  test "#load names the nested entry when a child is malformed" do
    Given "a dev.yml whose nested child has no body"
    tmp = write_dev_yml(<<~YAML)
      name: myproject
      commands:
        test:
          commands:
            unit:
              desc: nothing to run
    YAML

    When "loading the manifest"
    error = assert_raises(Dev::CommandParser::MissingBodyError) { build_loader.load(Pathname.new(tmp.path)) }

    Then "the error names the path as typed"
    error.message.include?("'test unit'")

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

  test "#load extracts the top-level engine sizing block (dev#307)" do
    Given "a dev.yml declaring the engine floor its build was tuned for"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      engine:
        cpus: 8
        memory_gib: 24
        disk_gib: 250
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the sizing rides the manifest as integers"
    manifest.engine == Dev::EngineResources::Hint.new(cpus: 8, memory_gib: 24, disk_gib: 250)

    Cleanup
    tmp.close!
  end

  test "#load leaves engine nil when the block is absent, and partial when half-declared" do
    Given "one dev.yml without engine and one declaring only cpus"
    without = write_dev_yml(<<~YAML)
      name: snappy
      commands:
        build:
          run: ./bin/build.sh
    YAML
    partial = write_dev_yml(<<~YAML)
      name: snappy
      engine:
        cpus: 6
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifests are loaded"
    no_engine = build_loader.load(Pathname.new(without.path)).engine
    partial_engine = build_loader.load(Pathname.new(partial.path)).engine

    Then
    no_engine.nil?
    partial_engine.cpus == 6
    partial_engine.memory_gib.nil?
    partial_engine.disk_gib.nil?

    Cleanup
    without.close!
    partial.close!
  end

  test "#load warns and ignores the retired runner block" do
    Given "a dev.yml still carrying the retired key"
    tmp = write_dev_yml(<<~YAML)
      name: unreal-engine
      runner:
        labels: ue-engine
    YAML
    old_stderr = $stderr
    $stderr = StringIO.new

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the manifest loads without it, with a retirement warning that names the label's real source"
    manifest.name == "unreal-engine"
    $stderr.string.include?("`runner:` is retired")
    $stderr.string.include?("derives from the repo name")
    !$stderr.string.include?("`name:`")

    Cleanup
    $stderr = old_stderr
    tmp.close!
  end

  test "#load refuses a dev.yml on the retired shape at load, every key with where it went (dev#307, dev#311)" do
    Given "a dev.yml still on the Dockerfile path: the block with its keys, and container: flags, one nested"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          persist: true
          volumes: ["/e:/ue"]
          run_env: { T: ns/t }
          build_args: { WWISE_EMAIL: audiokinetic/email }
          prewarm: ./bin/prewarm.sh
          resources: { cpus: 8 }
      commands:
        build:
          run: ./bin/build.sh
          container: true
        deploy:
          run: ./bin/deploy.sh
          container: false
        test:
          run: ./bin/test.sh
          commands:
            editor:
              run: ./bin/test-editor.sh
              container: false
    YAML

    When "the manifest is loaded"
    build_loader.load(Pathname.new(tmp.path))

    Then "one error, before any command exists: each key once, in document order, with its migration"
    error = raises(Dev::ProjectManifestLoader::RetiredKeysError)
    error.message.include?("declare an `image` block in dependencies.rb")
    error.message.include?("build.container.image → delete it")
    error.message.include?("build.container.persist → `persist true`")
    error.message.include?("build.container.volumes → `volume ")
    error.message.include?("build.container.run_env → `run_env ")
    error.message.include?("build.container.build_args → delete it")
    error.message.include?("build.container.prewarm → delete it")
    error.message.include?("build.container.resources → `engine:`")
    error.message.include?("commands.build.container: true → delete it")
    error.message.include?("commands.deploy.container: false → `runs_on: host`")
    error.message.include?("commands.test.commands.editor.container: false → `runs_on: host`")
    error.message.index("build.container.image") < error.message.index("commands.deploy.container")

    Cleanup
    tmp.close!
  end

  test "#load refuses an empty build.container block too: the block itself is retired" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container: {}
      commands:
        build: { run: ./bin/build.sh }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    error = raises(Dev::ProjectManifestLoader::RetiredKeysError)
    error.message.include?("build.container → delete the block")

    Cleanup
    tmp.close!
  end

  test "#load accepts a dev.yml on the new shape: engine at the top level, placement by runs_on" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      engine: { cpus: 8 }
      commands:
        build: { run: ./bin/build.sh, runs_on: snappy-linux }
        deploy: { run: ./bin/deploy.sh, runs_on: host }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.engine.cpus == 8
    manifest.commands["build"].runs_on == "snappy-linux"
    manifest.commands["deploy"].runs_on == "host"

    Cleanup
    tmp.close!
  end


  private

  def build_loader
    Dev::ProjectManifestLoader.new(command_parser: Dev::CommandParser.new)
  end

  def write_dev_yml(content)
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(content)
    tmp.flush
    tmp
  end
end
