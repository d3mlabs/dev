# frozen_string_literal: true

require "pathname"

module Dev
  module Cd
    # A git checkout discovered under the search root.
    #
    # - path: absolute Pathname of the repo root (directory containing `.git`)
    # - org:  owner / org segment (best-effort from path layout)
    # - name: leaf directory name (repo short name)
    Repo = Data.define(:path, :org, :name) do
      # @param path [Pathname, String]
      # @param org [String]
      # @param name [String]
      def initialize(path:, org:, name:)
        super(path: Pathname(path), org: org.to_s, name: name.to_s)
      end

      # Disambiguating `org/repo` label used in errors and completion.
      #
      # @return [String]
      def org_repo
        "#{org}/#{name}"
      end
    end
  end
end
