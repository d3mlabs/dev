# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container_config"
require "dev/engine_resources_check"
require "dev/settings"
require "support/fake_container_engine"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::EngineResourcesCheckTest < Minitest::Test
  GIB = 1_073_741_824

  # Hermetic settings: the machine's own engine_resources never decides a test.
  def build_settings(dir, mode: nil)
    if mode
      path = File.join(dir, "user", "config.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "engine_resources: #{mode}\n")
    end
    Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
  end

  # An engine whose `docker info` reports the given size.
  def engine_with(cpus:, memory_gib:, kind: :colima)
    FakeContainerEngine.new(kind: kind, capture_result: "#{cpus} #{memory_gib * GIB}")
  end

  def hint(cpus: nil, memory_gib: nil)
    Dev::BuildContainerConfig::Resources.new(cpus: cpus, memory_gib: memory_gib)
  end

  def setup
    @saved_env = ENV.delete("DEV_ENGINE_RESOURCES")
    @dir = Dir.mktmpdir("dev-engine-resources-check-")
    @out = StringIO.new
  end

  def teardown
    ENV["DEV_ENGINE_RESOURCES"] = @saved_env if @saved_env
    FileUtils.rm_rf(@dir)
  end

  test "an engine at or above the hint passes silently" do
    Given "a 12/24 engine"
    engine = engine_with(cpus: 12, memory_gib: 24)
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir), out: @out)

    When "checking against a hint it meets"
    check.check!(engine: engine, hint: hint(cpus: cpus, memory_gib: memory_gib))

    Then "nothing printed, nothing raised"
    @out.string.empty?

    Where
    cpus | memory_gib
    12   | 24
    8    | 16
    nil  | 24
    12   | nil
  end

  test "no hint, or an empty one, never consults the daemon" do
    Given "an engine whose capture would blow up if asked, and a #{shape} hint"
    engine = FakeContainerEngine.new(capture_result: ->(_args) { raise "docker info was called" })
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir), out: @out)

    When "checking with nothing declared"
    check.check!(engine: engine, hint: declared)

    Then
    engine.captures.empty?

    Where
    shape    | declared
    "absent" | nil
    "empty"  | Dev::BuildContainerConfig::Resources.new(cpus: nil, memory_gib: nil)
  end

  test "an unreachable daemon is not a shortfall — the docker call that follows reports it" do
    Given "an engine whose docker info yields nothing"
    engine = FakeContainerEngine.new(kind: :colima, capture_result: "")
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir), out: @out)

    When "checking"
    check.check!(engine: engine, hint: hint(cpus: 12, memory_gib: 24))

    Then
    @out.string.empty?
  end

  test "enforce (the default): an undersized engine is a typed failure whose message fits the engine kind" do
    Given "a 4/8 engine and a 12/24 hint"
    engine = engine_with(cpus: 4, memory_gib: 8, kind: kind)
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir), out: @out)

    When "checking"
    check.check!(engine: engine, hint: hint(cpus: 12, memory_gib: 24))

    Then
    error = raises Dev::EngineResourcesCheck::UndersizedEngineError
    error.message.include?("4 cpus / 8 GiB")
    error.message.include?("12 cpus / 24 GiB")
    error.message.include?(remedy)
    error.message.include?("engine_resources: warn")
    @out.string.empty?

    Where
    kind      | remedy
    :colima   | "Run `dev up` to resize the VM"
    :docker   | ".wslconfig"
    :explicit | "yours to resize"
  end

  test "a hint declaring one field is compared and reported on that field alone" do
    Given "an engine short on memory only"
    engine = engine_with(cpus: 16, memory_gib: 8)
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir), out: @out)

    When "checking a memory-only hint"
    check.check!(engine: engine, hint: hint(memory_gib: 24))

    Then
    error = raises Dev::EngineResourcesCheck::UndersizedEngineError
    error.message.include?("this project needs 24 GiB.")
  end

  test "warn: the shortfall is printed with the layer that relaxed it, and the command goes on" do
    Given "a 4/8 engine, a 12/24 hint, and warn set in the given layer"
    engine = engine_with(cpus: 4, memory_gib: 8)
    settings = build_settings(@dir, mode: user_mode)
    ENV["DEV_ENGINE_RESOURCES"] = env_mode if env_mode
    check = Dev::EngineResourcesCheck.new(settings: settings, out: @out)

    When "checking"
    check.check!(engine: engine, hint: hint(cpus: 12, memory_gib: 24))

    Then "two lines: the shortfall and the provenance of the relaxation"
    @out.string.include?("dev: warning: the colima VM has 4 cpus / 8 GiB; this project needs 12 cpus / 24 GiB.")
    @out.string.include?("dev: engine_resources: warn (#{source} config)")
    !@out.string.include?("DEV_ENGINE_RESOURCES=warn")

    Where
    user_mode | env_mode | source
    "warn"    | nil      | "user"
    nil       | "warn"   | "env"
  end

  test "an invalid engine_resources value surfaces as the settings error, not a silent enforce" do
    Given "a 4/8 engine and a misspelt setting"
    engine = engine_with(cpus: 4, memory_gib: 8)
    check = Dev::EngineResourcesCheck.new(settings: build_settings(@dir, mode: "ignore"), out: @out)

    When "checking"
    check.check!(engine: engine, hint: hint(cpus: 12, memory_gib: 24))

    Then
    raises Dev::Settings::InvalidSettingError
  end
end
