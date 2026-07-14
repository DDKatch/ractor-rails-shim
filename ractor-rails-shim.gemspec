# frozen_string_literal: true

require_relative "lib/ractor_rails_shim/version"

Gem::Specification.new do |spec|
  spec.name = "ractor-rails-shim"
  spec.version = RactorRailsShim::VERSION
  spec.authors = ["dev"]
  spec.email = ["dev@example.com"]

  spec.summary = "Monkey-patch Rails class-level globals to be Ractor-safe"
  spec.description = <<~DESC
    Rails stores global state (Rails.application, Rails.cache, Rails.logger,
    config set via mattr_accessor) in class-level instance variables, which
    are illegal to read or write from non-main Ractors. This shim reroutes
    those accessors through ActiveSupport::IsolatedExecutionState (which is
    already Ractor-safe, being thread-local with per-ractor threads) or
    Ractor.store_if_absent, so a Rails app can run in Ractor mode.

    This is a stopgap: the goal is for Rails to do this upstream, at which
    point the shim becomes a no-op and can be removed.
  DESC

  # Canonical repo URL. Update this (and the metadata below) before
  # publishing — rubygems.org displays these links on the gem page.
  REPO_URL = "https://github.com/DDKatch/ractor-rails-shim"

  spec.homepage = REPO_URL
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => REPO_URL,
    "changelog_uri" => "#{REPO_URL}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{REPO_URL}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # activesupport is a soft dependency: the shim uses
  # ActiveSupport::IsolatedExecutionState when Rails is loaded, and a
  # thread-local fallback when it isn't. Listed here so Bundler pulls it
  # in Rails apps; the gem works standalone too.
  spec.add_dependency "activesupport", ">= 7.0" unless ENV["NO_AS_DEP"]
end