# typed: true
# frozen_string_literal: true

# Add your extra requires here (`bin/tapioca require` can be used to bootstrap this list)

# mocha/minitest expects the old MiniTest constant (test_helper.rb aliases it, but
# that doesn't run during tapioca loading).
require "minitest"
MiniTest = Minitest unless defined?(MiniTest) # rubocop:disable Naming/ConstantName
require "mocha/minitest"
