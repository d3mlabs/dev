# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"
require "dev/project_manifest"
require "dev/environment_ref"
require "dev/project_manifest_loader"
require "dev/target_parser"
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
    error.message.include?("commands.deploy.container: false → `environment: host`")
    error.message.include?("commands.test.commands.editor.container: false → `environment: host`")
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

  test "#load refuses a command's runs_on: at load with its environment: replacement, nested commands included (dev#409)" do
    Given "a dev.yml still placing commands by runs_on, one value not even a name"
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      commands:
        build: { run: ./bin/build.sh, runs_on: snappy-linux }
        deploy: { run: ./bin/deploy.sh, runs_on: host }
        test:
          run: ./bin/test.sh
          commands:
            editor: { run: ./bin/editor.sh, runs_on: true }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then "one message: the key's new name, and each occurrence with its one-line replacement, in document order"
    error = raises(Dev::ProjectManifestLoader::RetiredKeysError)
    error.message.include?("`runs_on:` is `environment:`")
    error.message.include?("commands.build.runs_on: \"snappy-linux\" → `environment: snappy-linux`")
    error.message.include?("commands.deploy.runs_on: \"host\" → `environment: host`")
    error.message.include?("commands.test.commands.editor.runs_on: true → `environment: <image name> | host`")
    error.message.index("commands.build.runs_on") < error.message.index("commands.deploy.runs_on")
    error.message.index("commands.deploy.runs_on") < error.message.index("commands.test.commands.editor.runs_on")

    Cleanup
    tmp.close!
  end

  test "#load accepts a dev.yml on the new shape: engine at the top level, placement by environment, as unbound references" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      engine: { cpus: 8 }
      commands:
        build: { run: ./bin/build.sh, environment: snappy-linux }
        deploy: { run: ./bin/deploy.sh, environment: host }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.engine.cpus == 8
    manifest.commands["build"].environment == Dev::EnvironmentRef::Image.new(name: "snappy-linux")
    manifest.commands["deploy"].environment == Dev::EnvironmentRef::Host.new
    manifest.commands["build"].placement.nil?

    Cleanup
    tmp.close!
  end

  test "#load parses targets: into the manifest beside the commands, environment: as declared (dev#192)" do
    Given "cellbound-3d's declarations after adoption, minus the keys sibling milestones add"
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d-editor:
          desc: Editor
          platforms: [linux64, macos]
          environment: { linux64: cellbound-3d-linux, macos: host }
        cellbound-3d:
          desc: Client
          platforms: [win64, linux64]
          configs: [dev, release]
          environment: cellbound-3d-linux
        opencell:
          desc: Simulation library
      commands:
        deploy:
          desc: Ship an artifact to a channel
          commands:
            staging: { desc: rsync to the gamebox, targets: [cellbound-3d-win64], run: ./bin/stage }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.targets.keys == ["cellbound-3d-editor", "cellbound-3d", "opencell"]
    manifest.targets["cellbound-3d"].platforms == [Dev::Lifecycle::Platform::Win64, Dev::Lifecycle::Platform::Linux64]
    manifest.targets["cellbound-3d"].configs == [Dev::Lifecycle::Config::Development, Dev::Lifecycle::Config::Release]
    manifest.targets["cellbound-3d"].environment_for(Dev::Lifecycle::Platform::Win64) == Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux")
    manifest.targets["cellbound-3d-editor"].environment_for(Dev::Lifecycle::Platform::Linux64) == Dev::EnvironmentRef::Image.new(name: "cellbound-3d-linux")
    manifest.targets["cellbound-3d-editor"].environment_for(Dev::Lifecycle::Platform::Macos) == Dev::EnvironmentRef::Host.new
    manifest.targets["opencell"].builds.map(&:name) == ["opencell"]
    manifest.targets["opencell"].environment.nil?
    manifest.commands == {}
    manifest.channels.keys == ["staging"]

    Cleanup
    tmp.close!
  end

  test "#load lifts commands: deploy: out of the command tree as channels when targets are declared (dev#415)" do
    Given "two channels beside a plain command"
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d:
          platforms: [win64, linux64]
          configs: [dev, release]
          environment: cellbound-3d-linux
        cellbound-3d-server:
          platforms: [linux64]
          environment: cellbound-3d-linux
      commands:
        test: { run: ./bin/test }
        deploy:
          commands:
            staging:
              desc: rsync to the gamebox
              targets: [cellbound-3d-win64, cellbound-3d-server]
              run: ./bin/stage
              environment: host
            steam:
              targets: [cellbound-3d-release]
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then "the channels are parsed against the targets; the command tree holds only the plain command"
    manifest.commands.keys == ["test"]
    manifest.channels.keys == ["staging", "steam"]
    manifest.channels["staging"].desc == "rsync to the gamebox"
    manifest.channels["staging"].builds.map(&:name) == ["cellbound-3d-win64-dev", "cellbound-3d-win64-release", "cellbound-3d-server-linux64"]
    manifest.channels["staging"].publisher ==
      Dev::Lifecycle::PublisherSpec::Script.new(command: "./bin/stage", environment: Dev::EnvironmentRef::Host.new)
    manifest.channels["steam"].builds.map(&:name) == ["cellbound-3d-win64-release", "cellbound-3d-linux64-release"]
    manifest.channels["steam"].publisher == Dev::Lifecycle::PublisherSpec::Integration.new(name: "steam")

    Cleanup
    tmp.close!
  end

  test "#load surfaces a channel's faults from the parser and the pattern grammar: #{fault}" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d: { platforms: [win64] }
      commands:
        deploy:
          #{deploy_yaml}
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    raises error_class

    Cleanup
    tmp.close!

    Where
    fault                         | deploy_yaml                                                                | error_class
    "a run: on deploy"            | "run: ./bin/deploy"                                                        | Dev::ChannelParser::DeployBodyError
    "no channels"                 | "desc: Ship"                                                               | Dev::ChannelParser::NoChannelsError
    "a child without targets:"    | "commands: { staging: { run: ./bin/stage } }"                              | Dev::ChannelParser::ChannelAcceptsError
    "an environment: without run:" | "commands: { steam: { targets: [cellbound-3d], environment: host } }"     | Dev::ChannelParser::ChannelEnvironmentError
    "a child with children"       | "commands: { staging: { targets: [cellbound-3d], run: r, commands: {} } }" | Dev::ChannelParser::ChannelChildrenError
    "a child named help"          | "commands: { help: { targets: [cellbound-3d], run: r } }"                  | Dev::ChannelParser::ReservedChannelNameError
    "a pattern naming no target"  | "commands: { staging: { targets: [snappy], run: r } }"                     | Dev::Lifecycle::BuildPattern::UnknownTargetError
  end

  test "#load keeps deploy a plain command, children included, in a project without targets" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      commands:
        deploy:
          desc: Ship
          commands:
            staging: { run: ./bin/stage }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.channels == {}
    manifest.commands["deploy"].children.keys == ["staging"]

    Cleanup
    tmp.close!
  end

  test "#load refuses a channel-shaped deploy child in a project without targets: its patterns have nothing to name" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      commands:
        deploy:
          commands:
            staging: { targets: [snappy], run: ./bin/stage }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    error = raises(Dev::ProjectManifestLoader::ChannelWithoutTargetsError)
    error.message.include?("targets:")

    Cleanup
    tmp.close!
  end

  test "#load surfaces a target's environment: faults from the parser and the target: #{fault}" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d:
          platforms: [win64, linux64]
          environment: #{environment_yaml}
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    raises error_class

    Cleanup
    tmp.close!

    Where
    fault                       | environment_yaml                        | error_class
    "not a name"                | "[cellbound-3d-linux]"                  | Dev::TargetParser::InvalidEnvironmentError
    "a key outside the id set"  | "{ Win64: cellbound-3d-linux }"         | Dev::TargetParser::InvalidEnvironmentError
    "a platform left out"       | "{ win64: cellbound-3d-linux }"         | Dev::Lifecycle::Target::EnvironmentPlatformsError
  end

  test "#load leaves targets empty when the key is absent, and a project build: command is then a plain command" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      commands:
        build: { run: ./bin/build.sh }
        package: { run: ./bin/package.sh }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.targets == {}
    manifest.commands.keys == ["build", "package"]

    Cleanup
    tmp.close!
  end

  test "#load refuses commands: build: or package: beside targets:, since the verbs are derived (dev#192)" do
    Given "a dev.yml half-migrated: targets declared, the old build and package commands kept"
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d: { platforms: [win64], configs: [dev] }
      commands:
        build: { run: ./bin/build }
        package: { run: ./bin/package }
        test: { run: ./bin/test }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then "one message naming both keys and what to declare instead"
    error = raises(Dev::ProjectManifestLoader::DerivedCommandDeclaredError)
    error.message.include?("`commands: build:` and `commands: package:`")
    error.message.include?("build and package are derived from `targets:`")
    error.message.include?("a target's builder")

    Cleanup
    tmp.close!
  end

  test "#load refuses a single derived command too, in the singular" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      targets:
        snappy-steam: { platforms: [win64] }
      commands:
        build: { run: ./bin/build.sh }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    error = raises(Dev::ProjectManifestLoader::DerivedCommandDeclaredError)
    error.message.include?("declares `commands: build:` beside `targets:`, but build is derived")

    Cleanup
    tmp.close!
  end

  test "#load refuses a command named like a build or a pattern over the targets, at any depth (dev#192)" do
    Given "a command named as a target, and a nested one named as a build pattern"
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d: { platforms: [win64, linux64], configs: [dev, release] }
        opencell: {}
      commands:
        opencell: { run: ./bin/build-sim.sh }
        ship:
          commands:
            staging: { run: ./bin/stage }
            cellbound-3d-win64: { run: ./bin/stage-win }
        test: { run: ./bin/test }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then "one message listing every offender by path"
    error = raises(Dev::ProjectManifestLoader::BuildNamedCommandError)
    error.message.include?("'opencell', 'ship cellbound-3d-win64'")
    error.message.include?("`dev build <build>`")
    !error.message.include?("'test'")
    !error.message.include?("'ship staging'")

    Cleanup
    tmp.close!
  end

  test "#load refuses a single build-named command too, in the singular" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: snappy
      targets:
        snappy-steam: { platforms: [win64] }
      commands:
        snappy-steam-win64: { run: ./bin/build.sh }
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    error = raises(Dev::ProjectManifestLoader::BuildNamedCommandError)
    error.message.include?("names a command like a build: 'snappy-steam-win64'")

    Cleanup
    tmp.close!
  end

  test "#load accepts commands whose names merely share a prefix with a target but spell no build" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        cellbound-3d: { platforms: [win64], configs: [dev] }
      commands:
        cellbound-3d-editor: { run: ./bin/editor }
        s: { run: dev package && dev deploy staging }
    YAML

    When
    manifest = build_loader.load(Pathname.new(tmp.path))

    Then
    manifest.commands.keys == ["cellbound-3d-editor", "s"]

    Cleanup
    tmp.close!
  end

  test "#load surfaces the target parser's and the target's own errors unchanged: #{fault}" do
    Given
    tmp = write_dev_yml(<<~YAML)
      name: cellbound-3d
      targets:
        #{targets_yaml}
    YAML

    When
    build_loader.load(Pathname.new(tmp.path))

    Then
    raises error_class

    Cleanup
    tmp.close!

    Where
    fault                   | targets_yaml                                       | error_class
    "a reserved suffix"     | "cellbound-3d-win64: { platforms: [win64] }"       | Dev::Lifecycle::Target::ReservedTargetSuffixError
    "an unknown id"         | "cellbound-3d: { platforms: [windows-x64] }"       | Dev::TargetParser::InvalidAxisError
    "a non-mapping entry"   | "cellbound-3d: ./bin/build"                        | Dev::TargetParser::InvalidTargetError
  end

  private

  def build_loader
    Dev::ProjectManifestLoader.new(command_parser: Dev::CommandParser.new, target_parser: Dev::TargetParser.new)
  end

  def write_dev_yml(content)
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(content)
    tmp.flush
    tmp
  end
end
