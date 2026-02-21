# typed: true

module Minitest
  module Reporters
    def self.use!(reporters = T.unsafe(nil), options = T.unsafe(nil)); end

    class RakeRerunReporter; end
  end
end
