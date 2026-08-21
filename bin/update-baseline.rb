#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate share/baseline/deps.lock from share/baseline/dependencies.rb.
#
# dev-repo maintenance only: run here when the baseline manifest changes,
# commit the lock, release. Consuming hosts never resolve — they install
# the shipped pin (Dev::Deps::Baseline#converge via `dev up`).

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "dev/deps/baseline"

Dev::Deps::Baseline.new.update_lock!
puts "dev: baseline lock regenerated at #{Dev::Deps::Baseline::SHIPPED_DIR / "deps.lock"}"
