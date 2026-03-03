# typed: true

module Minitest
  module Reporters
    def self.use!(reporters = T.unsafe(nil), env = T.unsafe(nil), backtrace_filter = T.unsafe(nil)); end

    class RakeRerunReporter; end
  end
end
