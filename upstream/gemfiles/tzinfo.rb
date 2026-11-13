# frozen_string_literal: true

# Bundle for running the upstream tzinfo suite (tzinfo/tzinfo @ v2.0.6)
# against ractor-rails-shim. Suite deps mirror the checkout's Gemfile;
# activesupport is required by the shim's loader (patches/core.rb).
#
# The default `rake test` task runs the Ruby-format suites plus the
# zoneinfo suite (reads the system tzdata at /usr/share/zoneinfo — present
# on macOS and most Linux images).

source "https://rubygems.org"

gemspec path: File.expand_path("../checkouts/tzinfo", __dir__)

gem "ractor-rails-shim", path: File.expand_path("../..", __dir__)
gem "activesupport", "~> 8.0", require: false

# from the checkout's Gemfile (suite deps):
gem "rake", ">= 12.2.1", "< 14"
gem "minitest", "~> 5.0"
gem "simplecov", "~> 0.15.1", require: false
gem "json"
