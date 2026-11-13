# frozen_string_literal: true

# Bundle for running the upstream rack suite (rack/rack @ v3.2.8) against
# ractor-rails-shim. Suite deps mirror the checkout's Gemfile/gemspec;
# activesupport is required by the shim's loader (patches/core.rb).
#
# Suite: `rake test:regular` (the plain `test` task can pull in
# bake-test-external conformance runs — not wanted here).

source "https://rubygems.org"

gemspec path: File.expand_path("../checkouts/rack", __dir__)

gem "ractor-rails-shim", path: File.expand_path("../..", __dir__)
gem "activesupport", "~> 8.0", require: false

# from the checkout's Gemfile/gemspec (suite deps):
gem "rake"
gem "minitest", "~> 5.0"
gem "minitest-global_expectations"
gem "logger"
gem "webrick"
