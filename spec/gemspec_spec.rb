# frozen_string_literal: true

# Regression spec for the gemspec's activesupport dependency version.
# The shim only supports Rails 8.1 (per README, Version::TESTED_RAILS,
# and Version::SUPPORTED_RAILS), but the gemspec previously declared
# `spec.add_dependency "activesupport", ">= 7.0"`. That let Bundler
# resolve against ActiveSupport 7.x, where the shim's class-layout
# patches (class_attribute, Callbacks, PathRegistry, ...) would silently
# miss blockers or redefine the wrong methods. The dependency bound
# must match the documented support matrix so Bundler fails fast on an
# unsupported Rails version instead of letting the shim run broken.
#
# Run: ruby -Ilib -Ispec -e 'require "minitest/autorun"; require File.expand_path("spec/gemspec_spec.rb", dir__)'

require "minitest/autorun"
require "rubygems"

describe "gemspec activesupport dependency" do
  # Evaluate the gemspec in a controlled scope so we capture the
  # Gem::Specification instance. The gemspec file calls
  # `Gem::Specification.new do |spec| ... end` at load time, which
  # both adds the spec to Gem::Specification.stored_specs AND yields
  # it. We load it fresh here and find the spec by name.
  before do
    @spec = Gem::Specification.find_all_by_name("ractor-rails-shim").first
    refute_nil @spec, "gemspec should be loadable (run from the repo root)"
  end

  it "requires activesupport >= 8.1 (matching the documented Rails support matrix)" do
    dep = @spec.dependencies.find { |d| d.name == "activesupport" }
    refute_nil dep, "gemspec should declare an activesupport dependency"

    requirement = dep.requirement
    refute requirement.satisfied_by?(Gem::Version.new("7.1.0")),
      "activesupport dependency #{requirement} should NOT accept 7.1.0 (shim is broken on Rails 7.x)"
    assert requirement.satisfied_by?(Gem::Version.new("8.1.0")),
      "activesupport dependency #{requirement} should accept 8.1.0 (shim is tested on Rails 8.1)"
    assert requirement.satisfied_by?(Gem::Version.new("8.2.0")),
      "activesupport dependency #{requirement} should accept 8.2.0 (forward-compatible)"
  end

  it "declares the correct required_ruby_version (>= 4.0.6)" do
    # Pin the Ruby requirement too — it's documented in the README and
    # the shim relies on Ractor semantics + the frozen-iseq call-cache
    # fix (#22075) that shipped in 4.0.6.
    req = @spec.required_ruby_version
    assert req.satisfied_by?(Gem::Version.new("4.0.6")),
      "required_ruby_version #{req} should accept 4.0.6"
    refute req.satisfied_by?(Gem::Version.new("4.0.5")),
      "required_ruby_version #{req} should NOT accept 4.0.5 (shim relies on 4.0.6 fixes)"
  end
end