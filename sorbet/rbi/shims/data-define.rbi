# typed: true

# Sigs for Data.define-synthesized member readers, which Sorbet generates
# without sigs (error 7017 under `typed: strict`). The classes themselves
# stay strict; only the synthesized accessors need declaring here.
module Dev
  module Deps
    class Tap
      sig { returns(String) }
      def name; end

      sig { returns(T.nilable(URI::Generic)) }
      def url; end
    end
  end
end
