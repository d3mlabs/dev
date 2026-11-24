# typed: strict
# frozen_string_literal: true

require "yaml"
require "dev/deps/dependency"
require "dev/runner_role"
require "dev/runner_setup"
require_relative "runner_role_parser"

module Dev
  module Cli
    # Loads the role a dev.yml reference names (RunnerRole::Reference): the
    # declaring project's dev.yml, read from its repo at the version the
    # referencing checkout's lock pins for that repo, parsed in the one
    # `runner_roles:` grammar (RunnerRoleParser), its entry of the
    # reference's name taken as the declaration and bound at repo scope
    # (RunnerRole::Declaration#as_referenced).
    #
    # The version is the lock's, not the forge's newest: the referencing
    # project's jobs run the tool at the pinned version, so the role is
    # read where that tool's dev.yml is. A reference to a reference is
    # refused — a declaration is where a shape is stated once.
    #
    # One gh read, over the same Executor seam every runner-side gh read
    # rides (RunnerSetup::Executor), so tests hand a fake.
    class ReferencedRoleLoader
      extend T::Sig

      # gh could not read the declaring repo's dev.yml at the pinned
      # version — not there, not visible to this login, or gh refused.
      class QueryError < RuntimeError; end

      # The declaring project's dev.yml at the pinned version states no
      # declaration of the role's name: none, or a reference in its turn.
      class NotDeclaredError < RuntimeError; end

      # The declaring project's file the role is read from.
      DEV_YML = "dev.yml"

      # The contents API's media type for the file's bytes, not its JSON envelope.
      RAW_CONTENT = "Accept: application/vnd.github.raw"

      # The key of the block the declaration lives under.
      RUNNER_ROLES_KEY = "runner_roles"

      # @param executor [#capture] the gh CLI boundary (injectable for tests)
      # @param parser [RunnerRoleParser] the `runner_roles:` grammar
      sig { params(executor: T.untyped, parser: RunnerRoleParser).void }
      def initialize(executor: Dev::RunnerSetup::Executor.new, parser: RunnerRoleParser.new)
        @exec = executor
        @parser = parser
      end

      # The role the reference names, bound at repo scope.
      #
      # @param reference [Dev::RunnerRole::Reference]
      # @param pins [Array<Dev::Deps::Dependency>] the referencing checkout's lock
      # @return [Dev::RunnerRole]
      # @raise [Dev::RunnerRole::Reference::NotDependedOnError] when the lock pins nothing from the declaring repo
      # @raise [QueryError] when the declaring repo's dev.yml cannot be read at the pinned version
      # @raise [RunnerRoleParser::RunnerRoleError] when that dev.yml's `runner_roles:` is malformed
      # @raise [NotDeclaredError] when it declares no role of the reference's name
      sig { params(reference: Dev::RunnerRole::Reference, pins: T::Array[Deps::Dependency]).returns(Dev::RunnerRole) }
      def load(reference, pins)
        version = reference.pin(pins).version.to_s
        repo = reference.declaring_repo
        entry = @parser.parse_all(runner_roles_block(read_dev_yml(repo, version)))[reference.name]
        case entry
        when Dev::RunnerRole::Declaration
          entry.as_referenced
        when Dev::RunnerRole::Reference
          raise NotDeclaredError,
            "runner role '#{reference.name}' is referenced from #{repo}, whose #{DEV_YML} at #{version} references it in turn " \
              "(from #{entry.declaring_repo}) — a reference names the project that declares the role; reference #{entry.declaring_repo}"
        else
          raise NotDeclaredError,
            "runner role '#{reference.name}' is referenced from #{repo}, but its #{DEV_YML} at #{version} (the version this " \
              "checkout's lock pins) declares no such role — check the name against that project's `#{RUNNER_ROLES_KEY}:`"
        end
      end

      private

      # @param repo [String] the declaring project's "owner/repo"
      # @param version [String] the pinned version, a ref in that repo (its tag, or a commit)
      # @return [String] the file's bytes
      # @raise [QueryError]
      sig { params(repo: String, version: String).returns(String) }
      def read_dev_yml(repo, version)
        # `-f` on a GET rides the query string, so the ref needs no encoding here.
        out, err, ok = @exec.capture("gh", "api", "-X", "GET", "-H", RAW_CONTENT, "-f", "ref=#{version}", "repos/#{repo}/contents/#{DEV_YML}")
        return out if ok

        if err.include?("HTTP 404")
          raise QueryError,
            "#{repo} has no #{DEV_YML} at #{version}, or the repo is not visible to this gh login — a referenced role is read " \
              "from the declaring project's #{DEV_YML} at the version this checkout's lock pins"
        end

        raise QueryError, "could not read #{repo}'s #{DEV_YML} at #{version}: #{err.strip}"
      end

      # @param text [String] a dev.yml's bytes
      # @return [Object, nil] its `runner_roles:` value as YAML delivered it; nil when the document is not a mapping
      sig { params(text: String).returns(T.untyped) }
      def runner_roles_block(text)
        yaml = YAML.safe_load(text)
        yaml.is_a?(Hash) ? yaml[RUNNER_ROLES_KEY] : nil
      end
    end
  end
end
