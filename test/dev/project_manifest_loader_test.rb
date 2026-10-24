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

  test "#load extracts the build.container resources sizing block" do
    Given "a dev.yml whose container declares VM sizing for its provisioner"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          resources:
            cpus: 8
            memory_gib: 24
            disk_gib: 250
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifest is loaded"
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the sizing rides the config as integers"
    manifest.build_container.resources == Dev::BuildContainerConfig::Resources.new(cpus: 8, memory_gib: 24, disk_gib: 250)

    Cleanup
    tmp.close!
  end

  test "#load leaves resources nil when the block is absent, and partial when half-declared" do
    Given "one dev.yml without resources and one declaring only cpus"
    without = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    partial = write_dev_yml(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
          resources:
            cpus: 6
      commands:
        build:
          run: ./bin/build.sh
    YAML

    When "the manifests are loaded"
    no_resources = build_loader.load(Pathname.new(without.path)).build_container.resources
    partial_resources = build_loader.load(Pathname.new(partial.path)).build_container.resources

    Then
    no_resources.nil?
    partial_resources.cpus == 6
    partial_resources.memory_gib.nil?
    partial_resources.disk_gib.nil?

    Cleanup
    without.close!
    partial.close!
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
