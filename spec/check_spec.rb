# frozen_string_literal: true

# Specs for `RactorRailsShim::Check` — the audit scanner that powers the
# `ractor-rails-check` CLI. Verifies:
#   * class-level instance variables (@foo) and class variables (@@foo) are
#     correctly classified (`kind: :ivar` / `:cvar`)
#   * shareable values are filtered out; only unshareable values are reported
#   * `scan_rails` / `scan_app` split framework vs app+gems correctly
#   * `report` produces a human-readable summary and respects `print:`
#   * `safe_class` handles BasicObject (which lacks `.class`)
#
# Run: ruby -Ilib -Ispec spec/check_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/check"

# Test fixtures. Defined as *named* constants (anonymous classes/modules get
# deep-copied across Ractors, which would defeat the scan). Each fixture holds
# an unshareable value so the scanner reports it.
module CheckSpecFixtures
  # Holds a class-level instance variable with an unshareable value (a Mutex).
  module HolderIvar
    @lock = Mutex.new # unshareable
  end

  # Holds a class variable with an unshareable value (a mutable Array).
  module HolderCvar
    @@bag = [] # unshareable
  end

  # Holds a class-level instance variable with a SHAREABLE value — must be
  # filtered OUT by the scanner.
  module HolderShareable
    @frozen = [1, 2, 3].freeze
  end
end

# Rails-namespaced fixture so `scan_rails` picks it up. Defined at the top
# level so its `owner` string starts with "Rails::" (defining it under
# `CheckSpecFixtures::Rails` would prefix the owner with CheckSpecFixtures
# and defeat the scan_rails filter).
module Rails
  module CheckSpecFixture
    @thing = Mutex.new
  end
end unless defined?(::Rails)

class CheckSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # Helper: find a Finding by owner + ivar, returning nil if absent.
  def find(findings, owner, ivar)
    findings.find { |f| f.owner == owner && f.ivar == ivar }
  end

  it "classifies class-level instance variables as kind: :ivar" do
    findings = RactorRailsShim::Check.scan
    f = find(findings, "CheckSpecFixtures::HolderIvar", "@lock")
    refute_nil f, "expected @lock on CheckSpecFixtures::HolderIvar to be reported"
    assert_equal :ivar, f.kind
    # Ruby 4 may report "Thread::Mutex" or "Mutex" depending on version; just
    # confirm it's a Mutex-class value.
    assert_match(/Mutex\z/, f.value_class)
    refute f.shareable, "Mutex must be reported as unshareable"
  end

  it "classifies class variables as kind: :cvar" do
    findings = RactorRailsShim::Check.scan
    f = find(findings, "CheckSpecFixtures::HolderCvar", "@@bag")
    refute_nil f, "expected @@bag on CheckSpecFixtures::HolderCvar to be reported"
    assert_equal :cvar, f.kind
    assert_equal "Array", f.value_class
    refute f.shareable
  end

  it "filters out shareable values" do
    findings = RactorRailsShim::Check.scan
    assert_nil find(findings, "CheckSpecFixtures::HolderShareable", "@frozen"),
      "shareable frozen Array should NOT be reported"
  end

  it "scan_rails returns only Rails-namespaced findings" do
    rails = RactorRailsShim::Check.scan_rails
    assert(rails.all? { |f| f.owner.start_with?("Rails", "ActiveRecord", "ActiveSupport",
      "ActionController", "ActionView", "ActionDispatch", "ActionMailer",
      "ActiveJob", "ActionCable", "ActionText", "ActionMailbox", "ActiveStorage") },
      "scan_rails should only return Rails-namespaced owners")
    # Our Rails-namespaced fixture should appear.
    refute_nil find(rails, "Rails::CheckSpecFixture", "@thing")
  end

  it "scan_app excludes Rails-namespaced findings" do
    app = RactorRailsShim::Check.scan_app
    assert(app.none? { |f| f.owner.start_with?("Rails::") },
      "scan_app should not include Rails-namespaced owners")
    # Our non-Rails fixture should appear.
    refute_nil find(app, "CheckSpecFixtures::HolderIvar", "@lock")
  end

  it "scan_app and scan_rails partition scan (no overlap)" do
    all = RactorRailsShim::Check.scan
    rails = RactorRailsShim::Check.scan_rails
    app = RactorRailsShim::Check.scan_app
    # Same total count (scan - scan_rails == scan_app, by construction).
    assert_equal all.size, rails.size + app.size
    # No finding appears in both partitions.
    rails_keys = rails.map { |f| [f.owner, f.ivar] }.to_set
    app_keys = app.map { |f| [f.owner, f.ivar] }.to_set
    assert(rails_keys.disjoint?(app_keys), "scan_rails and scan_app overlap")
  end

  it "report returns a string and prints to $stderr when print: is true" do
    out, err = capture_io do
      str = RactorRailsShim::Check.report(print: true)
      assert_kind_of String, str
      assert_match(/ractor-rails-shim check:/, str)
    end
    assert_match(/ractor-rails-shim check:/, err,
      "report(print: true) should write to $stderr")
  end

  it "report does not print when print: is false" do
    out, err = capture_io do
      str = RactorRailsShim::Check.report(print: false)
      refute_empty str, "should still return the string"
    end
    assert_empty err, "report(print: false) should not write to $stderr"
  end

  it "report includes the blocker count and class-var tag" do
    str = RactorRailsShim::Check.report(print: false)
    # The header includes a "(N class-ivar, M class-var)" breakdown.
    assert_match(/\d+ blocker\(s\) found \(\d+ class-ivar, \d+ class-var\)/, str)
    # The cvar fixture is tagged as a shim target.
    assert_match(/@@bag.*\(mattr\/cattr — shim targets\)/, str)
  end

  it "safe_class handles BasicObject subclasses that lack .class" do
    # safe_class calls `val.class.name || val.class.to_s`, rescuing
    # NoMethodError (BasicObject and its subclasses don't inherit Kernel, so
    # `.class` may be undefined). For a normal Ruby object (Kernel-backed),
    # safe_class returns the class name. Verify both paths:
    #   1. A regular object returns its class name.
    assert_equal "String", RactorRailsShim::Check.send(:safe_class, "hi")
    #   2. A BasicObject subclass instance WITHOUT `.class` defined falls back
    #      to the "BasicObject" string via the NoMethodError rescue.
    basic = Class.new(BasicObject) # no `.class` method
    assert_equal "BasicObject", RactorRailsShim::Check.send(:safe_class, basic.new)
  end

  it "scan does not raise on modules whose class_variables enumeration fails" do
    # Some modules raise on .class_variables; the scan rescues and skips. We
    # can't easily synthesize one without monkey-patching, but we can confirm
    # scan runs to completion against the real loaded-module set (which
    # includes plenty of edge cases) without raising.
    assert_kind_of Array, RactorRailsShim::Check.scan
  end
end