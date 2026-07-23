# frozen_string_literal: true

require_relative "lib/ractor_rails_shim/version"

Gem::Specification.new do |spec|
  spec.name = "ractor-rails-shim"
  spec.version = RactorRailsShim::VERSION
  spec.authors = ["Daniil Kachur"]
  spec.email = ["kachur.daniil@gmail.com"]

  spec.summary = "Make Rails apps Ractor-safe so they can run in Ractor mode (e.g. under the kino web server)."
  spec.description = <<~DESC
    ractor-rails-shim makes a Rails application Ractor-safe, so it can run in
    Ractor mode — serving requests from worker Ractors that share one frozen
    app graph, instead of forking N separate processes.

    Rails keeps global state (Rails.application, Rails.cache, Rails.logger,
    and every config value set via mattr_accessor / class_attribute) in
    class-level instance variables, which Ruby forbids reading or writing from
    a non-main Ractor. The shim reroutes those accessors through Ractor-safe
    storage (ActiveSupport::IsolatedExecutionState, or Ractor.store_if_absent)
    and patches the handful of raw class-ivar accessors Rails reads
    per-request.

    It is verified against a real Rails 8.1 app (Devise, Propshaft, Kaminari,
    PostgreSQL) served by the kino web server in `kino -m ractor` mode.

    This is a stopgap: once Rails supports Ractor mode upstream, this gem
    becomes a no-op and can be removed.
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