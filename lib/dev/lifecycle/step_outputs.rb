# typed: strict
# frozen_string_literal: true

require "pathname"
require "securerandom"

module Dev
  module Lifecycle
    # The outputs of the Actions step a verb runs in (dev#192, K10): what
    # `dev package` tells the generic workflow about the artifact it
    # stamped — the build's name and the files to upload — so `--fetch`
    # can bring exactly those back by that name. GitHub's contract is the
    # file `GITHUB_OUTPUT` names, one `key=value` per line, a multi-line
    # value fenced with a delimiter; outside a job the variable is unset
    # and nothing is written. The one place dev writes a step output.
    class StepOutputs
      extend T::Sig

      ENV_VAR = "GITHUB_OUTPUT"
      ARTIFACT = "artifact"
      ARTIFACT_FILES = "artifact_files"

      class << self
        extend T::Sig

        # The step outputs of the enclosing job, or none outside one.
        #
        # @param env [Hash{String => String}] the environment to read, the process's own by default
        # @return [StepOutputs]
        sig { params(env: T::Hash[String, String]).returns(StepOutputs) }
        def from_env(env = ENV.to_h)
          path = env[ENV_VAR]
          new(path: path.nil? || path.empty? ? nil : Pathname(path))
        end
      end

      # @param path [Pathname, nil] the outputs file; nil outside a job
      sig { params(path: T.nilable(Pathname)).void }
      def initialize(path:)
        @path = path
      end

      # Whether a job is reading.
      #
      # @return [Boolean]
      sig { returns(T::Boolean) }
      def active?
        !@path.nil?
      end

      # Name the artifact a `package` stamped: its build and every file the
      # upload takes (the archive, its parts, the manifest).
      #
      # @param name [String] the build's name
      # @param files [Array<Pathname>]
      # @return [void]
      sig { params(name: String, files: T::Array[Pathname]).void }
      def artifact(name, files:)
        write(ARTIFACT, name)
        write(ARTIFACT_FILES, files.join("\n"))
      end

      private

      # Append one output; a value with a newline is fenced the way GitHub
      # reads it (`key<<DELIM … DELIM`), the delimiter random so no line of
      # the value can close the fence.
      #
      # @param key [String]
      # @param value [String]
      # @return [void]
      sig { params(key: String, value: String).void }
      def write(key, value)
        return unless @path

        line = if value.include?("\n")
          delimiter = "dev-#{SecureRandom.hex(8)}"
          "#{key}<<#{delimiter}\n#{value}\n#{delimiter}\n"
        else
          "#{key}=#{value}\n"
        end
        File.write(@path, line, mode: "a")
      end
    end
  end
end
