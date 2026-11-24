# typed: strict
# frozen_string_literal: true

require "dev/enrolled_runner"
require "dev/runner_group_contract"
require "dev/runner_role"

module Dev
  module Cli
    # Parses the dev.yml `runner_roles:` block into RunnerRole entries —
    # the dev.yml boundary for roles, as TargetParser is for targets. One
    # entry per key, in one of two shapes:
    #
    #   agent:                                   # a declaration (RunnerRole::Declaration)
    #     labels: [ai-ask, ai-build]
    #     group: ai-flow                         # or { name: ai-flow, visibility: all }
    #     workflows: [.github/workflows/ai-commands.yml]
    #     job_identity: ai-agent
    #   agent:                                   # a reference (RunnerRole::Reference)
    #     from: d3mlabs/ai-flow
    #
    # Coerced at the boundary: the labels a list of strings, the group a
    # name or a `{ name:, visibility: }` mapping, the workflows paths under
    # `.github/workflows/`, the job identity a user name, `from:` an
    # owner/repo. A group without workflows, or workflows without a group,
    # is refused here — only a group carries a pin, and a declared role's
    # group is pinned. `from:` stands alone: a reference borrows the shape
    # as the declaring project states it, so `from:` beside `labels:`,
    # `group:` or any other key is refused naming the key.
    #
    # The pins' repo and series are the project's, bound at register
    # (RunnerRole::Declaration#bind); the declaration itself is checked
    # against RunnerRole.declared's rules once, with a stand-in binding, so
    # a bad name or an empty label list is refused at parse time.
    #
    # Stateless: reusable across manifests, inputs arrive as method arguments.
    class RunnerRoleParser
      extend T::Sig

      # `runner_roles:` declares a role that cannot be (RunnerRole.declared's
      # rules), or not in a declaration's or a reference's shape.
      class RunnerRoleError < RuntimeError; end

      # The key that makes an entry a reference: the declaring project's repo.
      FROM_KEY = "from"

      # @param raw [Object, nil] the `runner_roles` block as YAML gave it
      # @return [Hash{String => Dev::RunnerRole::Entry}]
      # @raise [RunnerRoleError]
      sig { params(raw: T.untyped).returns(T::Hash[String, Dev::RunnerRole::Entry]) }
      def parse_all(raw)
        return {} unless raw.is_a?(Hash)

        raw.to_h do |name, body|
          raise RunnerRoleError, "dev.yml runner_roles: `#{name}` needs a mapping — `#{name}: { labels: [ue, gpu] }`" unless body.is_a?(Hash)

          [name.to_s, body.key?(FROM_KEY) ? parse_reference(name, body) : parse_declaration(name, body)]
        end
      end

      private

      # @param name [Object] the role's key
      # @param body [Hash] the entry's mapping
      # @return [Dev::RunnerRole::Declaration]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, body: T::Hash[T.untyped, T.untyped]).returns(Dev::RunnerRole::Declaration) }
      def parse_declaration(name, body)
        declaration = Dev::RunnerRole::Declaration.new(
          name: name.to_s,
          labels: labels(name, body["labels"]),
          group: group_name(name, body["group"]),
          visibility: visibility(name, body["group"]),
          workflows: workflows(name, body["workflows"]),
          job_identity: job_identity(name, body["job_identity"]),
        )
        validate_declaration!(declaration)
        declaration
      end

      # A reference: `from:` and nothing else. A key beside it would retype
      # part of the shape the reference borrows, so it is refused naming
      # the key and both ways out.
      #
      # @param name [Object] the role's key
      # @param body [Hash] the entry's mapping, carrying `from:`
      # @return [Dev::RunnerRole::Reference]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, body: T::Hash[T.untyped, T.untyped]).returns(Dev::RunnerRole::Reference) }
      def parse_reference(name, body)
        retyped = body.keys.map(&:to_s) - [FROM_KEY]
        unless retyped.empty?
          raise RunnerRoleError,
            "dev.yml runner_roles: `#{name}` references another project's declaration (`#{FROM_KEY}:`) and also declares " \
              "`#{retyped.join("`, `")}` — a referenced role borrows its shape as declared there; drop `#{FROM_KEY}:` to " \
              "declare the role here, or `#{retyped.join("`, `")}` to reference it"
        end

        from = body[FROM_KEY]
        unless from.is_a?(String) && !from.empty?
          raise RunnerRoleError,
            "dev.yml runner_roles: `#{name}` needs `#{FROM_KEY}:` as the declaring project's owner/repo — `#{name}: { #{FROM_KEY}: d3mlabs/ai-flow }`"
        end

        Dev::RunnerRole::Reference.new(name: name.to_s, declaring_repo: from)
      rescue Dev::EnrolledRunner::MalformedRepoError => e
        raise RunnerRoleError, "dev.yml runner_roles: `#{name}` `#{FROM_KEY}:` #{e.message}"
      end

      # @param name [Object] the role's key
      # @param raw [Object] the `labels:` value
      # @return [Array<String>]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, raw: T.untyped).returns(T::Array[String]) }
      def labels(name, raw)
        return raw if raw.is_a?(Array) && raw.all?(String)

        raise RunnerRoleError, "dev.yml runner_roles: `#{name}` needs a `labels:` list — `#{name}: { labels: [ue, gpu] }`"
      end

      # @param name [Object] the role's key
      # @param raw [Object] the `group:` value: nil, a name, or `{ name:, visibility: }`
      # @return [String, nil]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, raw: T.untyped).returns(T.nilable(String)) }
      def group_name(name, raw)
        return nil if raw.nil?
        return raw if raw.is_a?(String) && !raw.empty?
        return raw["name"] if raw.is_a?(Hash) && raw["name"].is_a?(String) && !raw["name"].empty?

        raise RunnerRoleError,
          "dev.yml runner_roles: `#{name}` has a `group:` that is neither a name nor `{ name: <group>, visibility: selected | all }`"
      end

      # @param name [Object] the role's key
      # @param raw [Object] the `group:` value
      # @return [String] GitHub's visibility; `selected` unless the mapping says `all`
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, raw: T.untyped).returns(String) }
      def visibility(name, raw)
        return Dev::RunnerGroupContract::SELECTED unless raw.is_a?(Hash) && raw.key?("visibility")

        visibility = raw["visibility"]
        return visibility if Dev::RunnerGroupContract::VISIBILITIES.include?(visibility)

        raise RunnerRoleError,
          "dev.yml runner_roles: `#{name}` group visibility is #{visibility.inspect} — " \
            "one of #{Dev::RunnerGroupContract::VISIBILITIES.join(" | ")}"
      end

      # @param name [Object] the role's key
      # @param raw [Object] the `workflows:` value: nil or a list of paths in the project
      # @return [Array<String>]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, raw: T.untyped).returns(T::Array[String]) }
      def workflows(name, raw)
        return [] if raw.nil?
        unless raw.is_a?(Array) && raw.all?(String) && !raw.empty?
          raise RunnerRoleError,
            "dev.yml runner_roles: `#{name}` needs `workflows:` as a list of this project's workflow paths " \
              "(#{Dev::RunnerRole::WORKFLOWS_DIR}<file>.yml)"
        end

        outside = raw.reject { |path| path.start_with?(Dev::RunnerRole::WORKFLOWS_DIR) }
        return raw if outside.empty?

        raise RunnerRoleError,
          "dev.yml runner_roles: `#{name}` pins #{outside.join(", ")} — a pinned workflow is one of this project's own, " \
            "under #{Dev::RunnerRole::WORKFLOWS_DIR}"
      end

      # @param name [Object] the role's key
      # @param raw [Object] the `job_identity:` value: nil or a user name
      # @return [String, nil]
      # @raise [RunnerRoleError]
      sig { params(name: T.untyped, raw: T.untyped).returns(T.nilable(String)) }
      def job_identity(name, raw)
        return nil if raw.nil?
        return raw if raw.is_a?(String) && !raw.empty?

        raise RunnerRoleError, "dev.yml runner_roles: `#{name}` has a `job_identity:` that is not a user name"
      end

      # The rules a declaration must satisfy regardless of the project it
      # binds to: its name and labels (RunnerRole.declared), and that a
      # group and its pins come together.
      #
      # @param declaration [Dev::RunnerRole::Declaration]
      # @return [void]
      # @raise [RunnerRoleError]
      sig { params(declaration: Dev::RunnerRole::Declaration).void }
      def validate_declaration!(declaration)
        if declaration.group.nil? && !declaration.workflows.empty?
          raise RunnerRoleError,
            "dev.yml runner_roles: `#{declaration.name}` pins workflows but names no `group:` — only a runner group carries a pin"
        end
        if declaration.group && declaration.workflows.empty?
          raise RunnerRoleError,
            "dev.yml runner_roles: `#{declaration.name}` names group '#{declaration.group}' but pins no `workflows:` — a declared " \
              "role's group is pinned to this project's own workflows; a human's group is a build host's (--group)"
        end

        # A stand-in repo and version: the pins' spelling is register's
        # business, the name and label rules are checked here.
        declaration.bind(repo: "owner/repo", version: "0.0.0")
      rescue Dev::RunnerRole::DeclarationError => e
        raise RunnerRoleError, "dev.yml runner_roles: #{e.message}"
      end
    end
  end
end
