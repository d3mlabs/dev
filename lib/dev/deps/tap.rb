# frozen_string_literal: true

module Dev
  module Deps
    # A declared Homebrew tap.
    #
    # - name: tap identifier (e.g. "d3mlabs/d3mlabs")
    # - url:  optional URL; file:// URLs are local taps resolved relative to project root
    Tap = Data.define(:name, :url) do
      def initialize(name:, url: nil)
        super(name:, url:)
      end

      # @return [Boolean] true if this is a local (file://) tap
      def local?
        url.is_a?(String) && url.start_with?("file://")
      end
    end
  end
end
