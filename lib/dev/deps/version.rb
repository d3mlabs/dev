# frozen_string_literal: true

module Dev
  module Deps
    VERSION = File.read(File.expand_path("../../../VERSION", __dir__)).strip
  end
end
