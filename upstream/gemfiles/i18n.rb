# frozen_string_literal: true

# Bundle for running the upstream i18n suite (ruby-i18n/i18n @ v1.15.2)
# against ractor-rails-shim. Used with BUNDLE_GEMFILE; the checkout's own
# Gemfile stays untouched. Suite deps mirror the checkout's Gemfile;
# activesupport is required by the shim's loader (patches/core.rb) and
# matches the shim's production environment.

source "https://rubygems.org"

gemspec path: File.expand_path("../checkouts/i18n", __dir__)

gem "ractor-rails-shim", path: File.expand_path("../..", __dir__)
gem "activesupport", "~> 8.0", require: false

# from the checkout's Gemfile (suite deps):
gem "mocha", "~> 2.1.0"
gem "test_declarative", "0.0.6"
gem "rake", "~> 13"
gem "minitest", "~> 5.14"
gem "json"
gem "racc"
