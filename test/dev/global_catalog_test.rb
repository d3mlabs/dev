# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/global_catalog"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::GlobalCatalogTest < Minitest::Test
  include SorbetHelper

  test "the catalog names exactly the global builtins" do
    Given "a catalog over stand-in accessors"
    catalog = build_catalog

    Expect "the six global nouns, each a Command"
    catalog.commands.keys.sort == %w[cd clone config cred learnings plan]
    catalog.commands.values.all? { |command| command.is_a?(Dev::Command) }
  end

  test "the tree is built once: dispatch and listing see the same instances" do
    Given "a catalog"
    catalog = build_catalog

    Expect "repeated reads return the same frozen hash"
    catalog.commands.equal?(catalog.commands)
    catalog.commands.frozen?
  end

  test "the injected accessors are the ones the leaves call" do
    Given "a catalog over an expecting cd accessor"
    cd = typed_mock(Dev::Cd::Accessor)
    cd.expects(:run).with(["--resolve", "dev"]).once
    catalog = build_catalog(cd_accessor: cd)

    When "calling the cd leaf"
    catalog.commands.fetch("cd").call(args: ["--resolve", "dev"], context: Dev::ExecutionContext.new(ui: typed_mock(Dev::Cli::Ui)))

    Then "the accessor was used"
    true
  end

  private

  def build_catalog(**accessors)
    defaults = {
      cd_accessor: typed_mock(Dev::Cd::Accessor),
      clone_accessor: typed_mock(Dev::Clone::Accessor),
      config_accessor: typed_mock(Dev::ConfigAccessor),
      cred_accessor: typed_mock(Dev::CredentialAccessor),
    }
    Dev::GlobalCatalog.new(out: StringIO.new, **defaults.merge(accessors))
  end
end
