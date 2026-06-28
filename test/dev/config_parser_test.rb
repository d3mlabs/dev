# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command"
require "dev/command_parser"
require "dev/config"
require "dev/config_parser"
require "tempfile"

transform!(RSpock::AST::Transformation)
class ConfigParserTest < Minitest::Test
  test "#parse returns Config with name and Command objects from dev.yml" do
    Given "a dev.yml file with name and commands"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
        test:
          run: rspec
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "we get the expected config"
    config.name == "myproject"
    config.commands["up"] == Dev::ShellCommand.new(run: "./bin/setup.rb", desc: "Setup", repl: false)
    config.commands["test"] == Dev::ShellCommand.new(run: "rspec", desc: "(no description)", repl: false)

    Cleanup
    tmp.close!
  end

  test "#parse raises ArgumentError when a command is missing run" do
    Given "a dev.yml file with a command without run"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          desc: Setup but no run
    YAML
    tmp.flush

    When "parsing the config"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    parser.parse(Pathname.new(tmp.path))

    Then "it raises ArgumentError"
    raises ArgumentError

    Cleanup
    tmp.close!
  end

  test "#parse with repl flag passes it through to Command" do
    Given "a dev.yml file with repl set"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        console:
          run: ./bin/console
          repl: true
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "the command has repl true"
    config.commands["console"].repl == true

    Cleanup
    tmp.close!
  end

  test "#parse ignores non-command top-level keys like ruby" do
    Given "a dev.yml file with a ruby key alongside commands"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      ruby: "4.0.1"
      commands:
        up:
          desc: Setup
          run: ./bin/setup.rb
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then "it parses successfully with the correct command"
    config.name == "myproject"
    config.commands["up"].run == "./bin/setup.rb"

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container config" do
    Given "a dev.yml file with build.container"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    !config.build_container.nil?
    config.build_container.image == "snappy-linux"
    config.build_container.registry == "jpduchesne89"
    config.build_container.image_ref == "jpduchesne89/snappy-linux"

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container volumes" do
    Given "a dev.yml file with container volumes"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.volumes == ["~/.dev/engines/unreal-engine-css:/ue"]

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container build_args credential refs" do
    Given "a dev.yml file with container build_args"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.build_args == {
      "WWISE_EMAIL" => "wwise/email",
      "WWISE_PASSWORD" => "wwise/password",
    }

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container run_env credential refs" do
    Given "a dev.yml file with container run_env"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.run_env == { "WWISE_TOKEN" => "wwise/token" }

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container build_secrets credential refs" do
    Given "a dev.yml file with container build_secrets"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.build_secrets == { "WWISE_TOKEN" => "wwise/token" }

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container content_globs" do
    Given "a dev.yml file with container content_globs"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.content_globs == ["Mods/*/Source/*/*.Build.cs"]

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container structure_globs" do
    Given "a dev.yml file with container structure_globs"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.structure_globs == ["Mods/*/Source/*/*.Build.cs"]

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container prewarm command" do
    Given "a dev.yml file with a container prewarm command"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.prewarm == "bash /work/bin/prewarm.sh"

    Cleanup
    tmp.close!
  end

  test "#parse defaults build.container prewarm to nil" do
    Given "a dev.yml file without a prewarm command"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.prewarm.nil?

    Cleanup
    tmp.close!
  end

  test "#parse defaults build.container build_secrets, content_globs and structure_globs to empty" do
    Given "a dev.yml file without build_secrets, content_globs or structure_globs"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.build_secrets == {}
    config.build_container.content_globs == []
    config.build_container.structure_globs == []

    Cleanup
    tmp.close!
  end

  test "#parse defaults build.container volumes to empty" do
    Given "a dev.yml file without container volumes"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.volumes == []

    Cleanup
    tmp.close!
  end

  test "#parse extracts build.container persist flag" do
    Given "a dev.yml file with persist: true"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.persist == true

    Cleanup
    tmp.close!
  end

  test "#parse defaults build.container persist to false" do
    Given "a dev.yml file without persist"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      build:
        container:
          image: snappy-linux
          registry: jpduchesne89
      commands:
        build:
          run: ./bin/build.sh
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.persist == false

    Cleanup
    tmp.close!
  end

  test "#parse returns nil build_container when not declared" do
    Given "a dev.yml without build.container"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          run: ./bin/setup.rb
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.build_container.nil?

    Cleanup
    tmp.close!
  end

  test "#parse extracts a runner block with string labels" do
    Given "a dev.yml file with a runner block"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: unreal-engine
      runner:
        labels: ue-engine
        dir: "~/actions-runner-ue"
        name: gaming-box
        version: "2.335.1"
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.runner == Dev::RunnerSetupConfig.new(
      labels: "ue-engine", dir: "~/actions-runner-ue", name: "gaming-box", version: "2.335.1",
    )

    Cleanup
    tmp.close!
  end

  test "#parse normalizes a runner labels list to comma-separated" do
    Given "a dev.yml file with a runner labels list"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: snappy
      runner:
        labels:
          - snappy
          - x64
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.runner.labels == "snappy,x64"
    config.runner.dir.nil?

    Cleanup
    tmp.close!
  end

  test "#parse returns nil runner when not declared" do
    Given "a dev.yml without a runner block"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      commands:
        up:
          run: ./bin/setup.rb
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.runner.nil?

    Cleanup
    tmp.close!
  end

  test "#parse returns nil runner when labels are absent" do
    Given "a dev.yml with a labelless runner block"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
      name: myproject
      runner:
        dir: "~/actions-runner"
    YAML
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.runner.nil?

    Cleanup
    tmp.close!
  end

  test "#parse handles container: false on individual commands" do
    Given "a dev.yml with container opt-out on a command"
    tmp = Tempfile.new(["dev", ".yml"])
    tmp.write(<<~YAML)
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
    tmp.flush

    When "the config is parsed"
    parser = Dev::ConfigParser.new(command_parser: Dev::CommandParser.new)
    config = parser.parse(Pathname.new(tmp.path))

    Then
    config.commands["build"].container == true
    config.commands["deploy"].container == false

    Cleanup
    tmp.close!
  end
end
