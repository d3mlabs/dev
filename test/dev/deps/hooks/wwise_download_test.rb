# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/hooks/wwise_download"

transform!(RSpock::AST::Transformation)
class Dev::Deps::Hooks::WwiseDownloadTest < Minitest::Test
  test "call builds correct wwise-cli argv and shells out" do
    Given "a hook with version, packages, and platforms"
    hook = Dev::Deps::Hooks::WwiseDownload.new(
      version: "2023.1.14.8770",
      packages: ["SDK", "Authoring"],
      platforms: ["Windows_vc160", "Linux"],
    )

    When "calling the hook"
    hook.expects(:system).with(
      "wwise-cli", "download",
      "--sdk-version", "2023.1.14.8770",
      "--filter", "Packages=SDK",
      "--filter", "Packages=Authoring",
      "--filter", "DeploymentPlatforms=Windows_vc160",
      "--filter", "DeploymentPlatforms=Linux",
    ).returns(true)

    hook.call("wwise-cli", {})

    Then "system was called with correct args"
  end

  test "call works with no packages or platforms" do
    Given "a hook with only version"
    hook = Dev::Deps::Hooks::WwiseDownload.new(version: "2024.1.0.1234")

    When "calling the hook"
    hook.expects(:system).with(
      "wwise-cli", "download",
      "--sdk-version", "2024.1.0.1234",
    ).returns(true)

    hook.call("wwise-cli", {})

    Then "system was called with version only"
  end
end
