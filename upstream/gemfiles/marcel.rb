# frozen_string_literal: true

# Bundle for running the upstream marcel suite (rails/marcel @ v1.2.1)
# against ractor-rails-shim. Suite deps mirror the checkout's gemspec
# (the gemspec helper pulls the development dependencies, including the
# rack/nokogiri ones used only by table-generation tasks);
# activesupport is required by the shim's loader (patches/core.rb).

source "https://rubygems.org"

gemspec path: File.expand_path("../checkouts/marcel", __dir__)

gem "ractor-rails-shim", path: File.expand_path("../..", __dir__)
gem "activesupport", "~> 8.0", require: false

# from the checkout's gemspec (suite deps):
gem "minitest", "~> 5.11"
gem "rake", ">= 13.0"
