# typed: false
# frozen_string_literal: true

require "test_helper"

# bin/docker-install-build-deps.sh runs only inside `docker build`, so its
# contract is checked the way the other shipped scripts' are: readable from
# the text, plus a syntax check. The property under test is the one the
# ADR's "the image contains no dev" rule does not ask for and every cold
# container start paid for anyway: dev-core leaves the image, but the
# formulae it pulled in (gh, git, rbenv, ruby-build, shadowenv, …) stay, so
# bin/container-provision-dev.sh pours one formula rather than thirty.
transform!(RSpock::AST::Transformation)
class Dev::BinDockerInstallBuildDepsTest < Minitest::Test
  DEV_ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(DEV_ROOT, "bin", "docker-install-build-deps.sh")

  test "dev-core is removed without autoremoving the formulae it depends on" do
    Given "the image bootstrap script"
    script = File.read(SCRIPT)

    Expect "the uninstall opts out of Homebrew's autoremove (the default since Homebrew 7)"
    script.match?(/^HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --quiet dev-core$/)
  end

  test "the script parses under bash -n" do
    Expect "a clean syntax check"
    system("bash", "-n", SCRIPT)
  end
end
