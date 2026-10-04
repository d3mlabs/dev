# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cold_root"
require "dev/data_root"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ColdRootTest < Minitest::Test
  def setup
    @warm = Pathname(Dir.mktmpdir("cold-root-warm-"))
    @original = ENV.fetch("DEV_DATA_ROOT", nil)
  end

  def teardown
    restore_env(@original)
    FileUtils.rm_rf(@warm)
    Dir.glob("#{@warm}-cold-*").each { |leftover| FileUtils.rm_rf(leftover) }
  end

  test "with creates a sibling throwaway root, points DEV_DATA_ROOT at it for the block, then restores and removes it" do
    Given "a warm root and a known starting DEV_DATA_ROOT"
    ENV["DEV_DATA_ROOT"] = @warm.to_s
    seen = {}

    When "running a block in a cold root"
    Dev::ColdRoot.with(warm_root: @warm.to_s) do |root|
      seen[:root] = root
      seen[:exists] = root.directory?
      seen[:env] = ENV.fetch("DEV_DATA_ROOT", nil)
      seen[:resolved] = Dev::DataRoot.path
      (root / "marker").write("cold")
    end

    Then "the block saw a fresh sibling of the warm root as the data root; afterwards it is gone and the env is back"
    seen[:root].to_s.start_with?("#{@warm}-cold-")
    seen[:exists] == true
    seen[:env] == seen[:root].to_s
    seen[:resolved] == seen[:root].to_s
    !seen[:root].exist?
    ENV.fetch("DEV_DATA_ROOT", nil) == @warm.to_s
    @warm.directory?
  end

  test "with restores an unset DEV_DATA_ROOT to unset, and removes the root even when the block raises" do
    Given "no DEV_DATA_ROOT"
    ENV.delete("DEV_DATA_ROOT")
    seen = {}

    When "the block fails"
    begin
      Dev::ColdRoot.with(warm_root: @warm.to_s) do |root|
        seen[:root] = root
        raise "install exploded"
      end
    rescue RuntimeError
      nil
    end

    Then "the env is unset again and the throwaway is gone"
    !ENV.key?("DEV_DATA_ROOT")
    !seen[:root].exist?
  end

  test "two cold roots over the same warm root never collide" do
    Given "two runs"
    roots = []

    When "each records its root"
    Dev::ColdRoot.with(warm_root: @warm.to_s) { |root| roots << root }
    Dev::ColdRoot.with(warm_root: @warm.to_s) { |root| roots << root }

    Then "the paths differ"
    roots.uniq.size == 2
  end

  private

  def restore_env(value)
    if value.nil?
      ENV.delete("DEV_DATA_ROOT")
    else
      ENV["DEV_DATA_ROOT"] = value
    end
  end
end
