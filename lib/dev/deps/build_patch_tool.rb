# typed: strict
# frozen_string_literal: true

require "open3"
require "pathname"

module Dev
  module Deps
    # Epic's BuildPatchTool, the one command line to the Epic Games Store's
    # binaries: what the `egs` integration installs (the zip Epic serves,
    # unpacked into a store tree) and what the `egs` publisher runs
    # (`UploadBinary`, then `LabelBinary`). This module is the facts the
    # two share: where the tool comes from, where its binary sits in the
    # tree for each host OS, and how it is invoked.
    #
    # The client secret never rides the command line: BuildPatchTool reads
    # it from the environment variable `ClientSecretEnvVar` names, which is
    # Epic's own recommendation, so the secret is in the child's
    # environment and nowhere else.
    module BuildPatchTool
      extend T::Sig

      # The tool's name — the dependency a project declares (`egs "BuildPatchTool"`).
      NAME = "BuildPatchTool"

      # Epic's public download of the tool; the Dev Portal's "Download
      # Tool" button points here. A project may name a mirror instead.
      DOWNLOAD_URL = "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/BuildPatchTool.zip"

      # The binary inside the unpacked zip, per host OS (Dev::Platform.os).
      BINARIES = T.let(
        {
          "darwin" => "Engine/Binaries/Mac/BuildPatchTool",
          "linux" => "Engine/Binaries/Linux/BuildPatchTool",
          "windows" => "Engine/Binaries/Win64/BuildPatchTool.exe",
        }.freeze,
        T::Hash[String, String],
      )

      # The variable the secret rides in, named to the tool with `-ClientSecretEnvVar`.
      CLIENT_SECRET_ENV_VAR = "DEV_EGS_CLIENT_SECRET"

      class << self
        extend T::Sig

        # The tool's binary for a host, inside its installed tree.
        #
        # @param tree [Pathname] the published tree EgsIntegration installed
        # @param host [String] Dev::Platform.os
        # @return [Pathname]
        sig { params(tree: Pathname, host: String).returns(Pathname) }
        def binary(tree, host:)
          tree / BINARIES.fetch(host)
        end

        # Run the tool once and wait: the process boundary, isolated so a
        # test hands back what Epic's service would have said.
        #
        # @param binary [Pathname]
        # @param arguments [Array<String>] the `-Key=value` arguments
        # @param env [Hash{String => String}] variables added to dev's own — the secret's
        # @return [Array(String, String, Process::Status)] stdout, stderr, status
        sig { params(binary: Pathname, arguments: T::Array[String], env: T::Hash[String, String]).returns([String, String, Process::Status]) }
        def run(binary, arguments, env:)
          T.unsafe(Open3).capture3(env, binary.to_s, *arguments)
        end
      end
    end
  end
end
