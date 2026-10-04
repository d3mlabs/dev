# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_ruby"
require "dev/deps/local_store"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ContainerRubyTest < Minitest::Test
  # A builder that lays down a fake ruby reporting +reports+ (default: the
  # requested version) whose `-e` probes succeed unless +extensions_ok+ is false.
  class FakeBuilder < Dev::RubyBuild
    attr_reader :calls

    def initialize(reports: nil, extensions_ok: true, succeed: true)
      super()
      @reports = reports
      @extensions_ok = extensions_ok
      @succeed = succeed
      @calls = []
    end

    def call(version, prefix)
      @calls << [version, prefix]
      return false unless @succeed

      ContainerRubyTest.write_fake_ruby(prefix, reports: @reports || version, extensions_ok: @extensions_ok)
      true
    end
  end

  class << self
    def write_fake_ruby(ruby_root, reports:, extensions_ok: true)
      bin = Pathname(ruby_root) / "bin"
      bin.mkpath
      fake_ruby = bin / "ruby"
      fake_ruby.write(<<~SCRIPT)
        #!/bin/sh
        case "$2" in
          "print RUBY_VERSION") printf '%s' "#{reports}"; exit 0 ;;
        esac
        exit #{extensions_ok ? 0 : 1}
      SCRIPT
      fake_ruby.chmod(0o755)
    end
  end

  def setup
    @data_root = Pathname(Dir.mktmpdir("container-ruby-data-"))
    @project = Pathname(Dir.mktmpdir("container-ruby-project-"))
    @store = Dev::Deps::LocalStore.new(data_root: @data_root.to_s)
    @ruby_dir = @data_root / "ruby" / "linux-x86_64" / "4.0.6"
    @gem_home = @data_root / "gems" / "linux-x86_64" / "4.0.6"
    @lisp = @project / ".shadowenv.d" / Dev::ContainerRuby::LISP_FILENAME
  end

  def teardown
    FileUtils.rm_rf(@data_root)
    FileUtils.rm_rf(@project)
  end

  def subject(builder = FakeBuilder.new)
    Dev::ContainerRuby.new(store: @store, platform: "linux-x86_64", builder: builder)
  end

  test "ensure! builds the ruby into the platform-keyed store tree, makes the gem workdir, and writes a container-only lisp" do
    Given "an empty data root and project"
    builder = FakeBuilder.new

    When "the project's Ruby is ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "ruby-build ran once into the store path and the tree is published"
    builder.calls == [["4.0.6", @ruby_dir]]
    (@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).read == "4.0.6"
    @gem_home.directory?
    lisp = @lisp.read
    lisp.start_with?(%[(when-let ((inside (env/get "#{Dev::ContainerContext::MARKER}")))\n])
    lisp.include?(%[(provide "ruby" "4.0.6")])
    lisp.include?(%[(env/set "RUBY_ROOT" "#{@ruby_dir}")])
    lisp.include?(%[(env/set "GEM_HOME" "#{@gem_home}")])
    !lisp.include?('(env/get "HOME")')
  end

  test "ensure! is a no-op once the lisp provides the version and the ruby tree is published" do
    Given "a provisioned project"
    subject.ensure!(ruby_version: "4.0.6", project_root: @project)
    builder = FakeBuilder.new

    When "ensured again"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "nothing is built"
    builder.calls == []
  end

  test "ensure! rewrites the lisp without rebuilding when the ruby is published but the lisp is stale" do
    Given "a published ruby and a lisp providing another version"
    subject.ensure!(ruby_version: "4.0.6", project_root: @project)
    @lisp.write(@lisp.read.sub('(provide "ruby" "4.0.6")', '(provide "ruby" "4.0.5")'))
    builder = FakeBuilder.new

    When "ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "the lisp is current again and the tree was reused"
    builder.calls == []
    @lisp.read.include?('(provide "ruby" "4.0.6")')
  end

  test "ensure! raises BuildFailedError and publishes nothing when ruby-build fails" do
    Given "a builder that fails"
    builder = FakeBuilder.new(succeed: false)

    When "ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "the failure is typed and no marker, lisp, or gem home appears"
    error = raises Dev::ContainerRuby::BuildFailedError
    error.message.include?("4.0.6")
    error.message.include?(@ruby_dir.to_s)
    !(@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).exist?
    !@lisp.exist?
  end

  test "ensure! raises MissingExtensionsError when the built ruby cannot load a required extension" do
    Given "a builder whose ruby fails its extension probes"
    builder = FakeBuilder.new(extensions_ok: false)

    When "ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "the failure names the ruby and the tree stays unpublished"
    error = raises Dev::ContainerRuby::MissingExtensionsError
    error.message.include?(@ruby_dir.to_s)
    !(@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).exist?
  end

  test "ensure! raises ReportedVersionError when the built ruby runs as another version (#204)" do
    Given "a builder whose ruby reports a hijacked version"
    builder = FakeBuilder.new(reports: "4.0.7")

    When "ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "the failure names both versions and the tree stays unpublished"
    error = raises Dev::ContainerRuby::ReportedVersionError
    error.message.include?("4.0.6")
    error.message.include?("4.0.7")
    !(@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).exist?
  end

  test "ensure! rebuilds over a markerless leftover from an interrupted build" do
    Given "a half-built tree with no marker"
    (@ruby_dir / "bin").mkpath
    (@ruby_dir / "bin" / "stale").write("")
    builder = FakeBuilder.new

    When "ensured"
    subject(builder).ensure!(ruby_version: "4.0.6", project_root: @project)

    Then "the leftover is gone and the build ran"
    builder.calls == [["4.0.6", @ruby_dir]]
    !(@ruby_dir / "bin" / "stale").exist?
    (@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).read == "4.0.6"
  end

  test "converge! rebuilds a published ruby that has come to run as another version" do
    Given "a published, lisp-current ruby that now reports a different version"
    subject.ensure!(ruby_version: "4.0.6", project_root: @project)
    ContainerRubyTest.write_fake_ruby(@ruby_dir, reports: "4.0.7")
    builder = FakeBuilder.new

    When "converged"
    subject(builder).converge!(ruby_version: "4.0.6", project_root: @project)

    Then "the tree was rebuilt and is healthy again"
    builder.calls == [["4.0.6", @ruby_dir]]
    (@ruby_dir / Dev::ContainerRuby::RUBY_MARKER).read == "4.0.6"
  end

  test "converge! leaves a published, healthy ruby alone" do
    Given "a provisioned project"
    subject.ensure!(ruby_version: "4.0.6", project_root: @project)
    builder = FakeBuilder.new

    When "converged"
    subject(builder).converge!(ruby_version: "4.0.6", project_root: @project)

    Then "nothing is rebuilt"
    builder.calls == []
  end

  test "provisioned? is false until both the lisp and the published tree exist" do
    Given "a fresh project"
    ruby = subject
    before = ruby.provisioned?("4.0.6", project_root: @project)

    When "provisioned, then the tree is removed from under the lisp"
    ruby.ensure!(ruby_version: "4.0.6", project_root: @project)
    after = ruby.provisioned?("4.0.6", project_root: @project)
    @store.remove_tree(Dev::ContainerRuby.ruby_key("4.0.6", platform: "linux-x86_64"))
    without_tree = ruby.provisioned?("4.0.6", project_root: @project)

    Then "only the fully provisioned state counts"
    before == false
    after == true
    without_tree == false
  end
end
