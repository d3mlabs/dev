# typed: false
# frozen_string_literal: true

require "open3"
require "pathname"

# Real per-target Alpakit zips in a temporary directory, laid out as Alpakit
# stages them (`<ModRef>.uplugin` at the root, `Resources/Icon128.png`, the
# cooked paks under `Content/Paks/<target>/`, the binaries under
# `Binaries/<arch>/`) and zipped with the same `zip` the merger reads back
# with `unzip`. Pure builders over the caller's directory — nothing shared.
module AlpakitFixtures
  UPLUGIN = '{"FileVersion": 3, "Version": 1, "SemVersion": "1.2.0", "FriendlyName": "Snappy"}'
  ICON = "PNG".b

  # Write a staged plugin tree.
  #
  # @param dir [Pathname] the tree's root; created
  # @param mod_reference [String]
  # @param target [String] the cook platform (`Windows`, `LinuxServer`, …)
  # @param binaries [Hash{String => String}] relative path under the root => bytes, the target-specific files
  # @param pak [String] the pak's bytes — what two builds of one target share, or not
  # @param uplugin [String] the descriptor's bytes — the same for every target, unless a test says otherwise
  # @return [Pathname] the root
  def stage_plugin(dir, mod_reference:, target:, binaries: {}, pak: "pak-#{target}", uplugin: UPLUGIN)
    dir.mkpath
    (dir / "#{mod_reference}.uplugin").write(uplugin)
    (dir / "Resources").mkpath
    (dir / "Resources" / "Icon128.png").binwrite(ICON)
    paks = dir / "Content" / "Paks" / target
    paks.mkpath
    (paks / "#{mod_reference}FactoryGame-#{target}.pak").write(pak)
    binaries.each do |relative, bytes|
      (dir / relative).dirname.mkpath
      (dir / relative).binwrite(bytes)
    end
    dir
  end

  # Zip a staged tree the way Alpakit does: the tree's contents at the
  # zip's root.
  #
  # @param dir [Pathname] the staged tree
  # @param zip [Pathname] where to write
  # @return [Pathname] the zip
  def zip_plugin(dir, zip)
    zip.dirname.mkpath
    _out, status = Open3.capture2("zip", "-r", "-q", zip.to_s, ".", chdir: dir.to_s)
    raise "zip failed for #{dir}" unless status.success?

    zip
  end

  # Stage and zip in one step.
  #
  # @param root [Pathname] a directory to work in
  # @param name [String] the zip's stem and the staging directory's name
  # @return [Pathname] the zip
  def alpakit_zip(root, name, **plugin)
    zip_plugin(stage_plugin(root / "staged" / name, **plugin), root / "zips" / "#{name}.zip")
  end

  # The entries of a zip, as `unzip -Z1` lists them.
  #
  # @param zip [Pathname]
  # @return [Array<String>] sorted, directories excluded
  def zip_entries(zip)
    out, status = Open3.capture2("unzip", "-Z1", zip.to_s)
    raise "unzip failed for #{zip}" unless status.success?

    out.lines.map(&:chomp).reject { |entry| entry.end_with?("/") }.sort
  end
end
