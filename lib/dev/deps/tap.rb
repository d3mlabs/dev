# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "uri"

module Dev
  module Deps
    # A declared Homebrew tap.
    #
    # - name: tap identifier (e.g. "d3mlabs/d3mlabs")
    # - url:  optional URI; file:// URIs are local taps resolved relative to project root
    Tap = Data.define(:name, :url) do
      extend T::Sig

      # @param name [String] tap identifier
      # @param url [String, nil] tap URL; file:// means a local tap
      sig { params(name: String, url: T.nilable(String)).void }
      def initialize(name:, url: nil)
        super(name:, url: url ? URI(url).freeze : nil)
      end

      # @return [Boolean] true if this is a local (file://) tap
      sig { returns(T::Boolean) }
      def local?
        url&.scheme == "file"
      end
    end
  end
end
