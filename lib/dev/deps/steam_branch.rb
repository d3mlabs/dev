# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../value_equality"

module Dev
  module Deps
    # A Steam app's branch — the coordinate a steam declaration's universe
    # lives at: an app id and the branch whose tip is served (`1690800`,
    # `public`). Written as `<app>/<branch>` in a declaration's source
    # field, the way a tap or an `owner/repo` slug rides there for other
    # channels; the DSL writes it, SteamRepository reads it back.
    class SteamBranch
      extend T::Sig
      include Dev::ValueEquality::Derived

      # The source is not `<app>/<branch>`.
      class InvalidSourceError < StandardError; end

      # The branch a declaration names when it names none.
      DEFAULT_BRANCH = "public"

      SEPARATOR = "/"

      # @return [String] the Steam app id
      sig { returns(String) }
      attr_reader :app

      # @return [String] the branch name
      sig { returns(String) }
      attr_reader :branch

      # @param app [String] the Steam app id
      # @param branch [String] the branch name
      sig { params(app: String, branch: String).void }
      def initialize(app:, branch: DEFAULT_BRANCH)
        @app = app
        @branch = branch
        freeze
      end

      # @return [String] `<app>/<branch>`
      sig { returns(String) }
      def to_s
        "#{app}#{SEPARATOR}#{branch}"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [app, branch]
      end

      class << self
        extend T::Sig

        # @param source [String] `<app>/<branch>`
        # @return [SteamBranch]
        # @raise [InvalidSourceError] if either part is missing
        sig { params(source: String).returns(SteamBranch) }
        def parse(source)
          app, branch = source.split(SEPARATOR, 2)
          if app.nil? || app.empty? || branch.nil? || branch.empty?
            raise InvalidSourceError, "#{source.inspect} is not a Steam branch coordinate (`<app id>/<branch>`)"
          end

          new(app: app, branch: branch)
        end
      end
    end
  end
end
