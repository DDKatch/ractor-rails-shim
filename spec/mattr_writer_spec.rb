# frozen_string_literal: true

# Regression spec for the redundant class_variable_set bug in
# mattr_accessor.rb's writer. The shim-generated writer body previously
# had:
#
#   class_variable_set(cv, val) if   class_variable_defined?(cv)
#   class_variable_set(cv, val) unless class_variable_defined?(cv)
#
# These two guards are complementary: in the steady state (cvar already
# defined) only the first runs; in the initial state (cvar undefined)
# only the second runs. Together they're equivalent to a single
# unconditional `class_variable_set(cv, val)`, but expressed as two
# confusing lines with a wasted `class_variable_defined?` per write.
# This spec pins the contract: exactly one class_variable_set per
# writer invocation in the main ractor, so a refactor to the single
# line can be verified behavior-preserving.
#
# Run: ruby -Ilib -Ispec -e 'require "minitest/autorun"; require File.expand_path("spec/mattr_writer_spec.rb", dir__)'

require "minitest/autorun"
require "set"
require "active_support/class_attribute"
require "active_support/execution_wrapper"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Minimal mattr_accessor stub on Module, so super in the prepended patch
# finds it (matches shim_spec.rb / sentinel_spec.rb setup).
unless Module.method_defined?(:mattr_accessor, true)
  Module.module_eval do
    def mattr_accessor(name, default: nil, **)
      cv = "@@#{name}"
      class_variable_set(cv, default) unless class_variable_defined?(cv)
      define_singleton_method(name) { class_variable_get(cv) }
      define_singleton_method("#{name}=") { |v| class_variable_set(cv, v) }
    end
  end
end

RactorRailsShim.send(:install_mattr_accessor)

# Test module whose mattr writer we instrument.
module MattrWriterCountTest
  mattr_accessor :value, default: :initial
end

describe "mattr_accessor writer cvar-set count" do
  it "calls class_variable_set exactly once per writer invocation in main ractor" do
    # The shim defines the writer via `singleton_class.module_eval(STRING)`,
    # which installs the method DIRECTLY on the singleton class (not via
    # prepend). To intercept the inner `class_variable_set` call we prepend
    # a wrapper module AFTER the shim has installed the writer — prepend
    # sits in front of the singleton class in the lookup chain, so the
    # shim's `class_variable_set` calls inside the writer hit our override
    # first (class_variable_set is a method on Module, resolved via the
    # same lookup chain).
    # The shim passes the cvar name as a STRING ("@@value") to
    # class_variable_set (cv_str = "@@#{sym}".inspect), so the filter
    # must match either form.
    cvar_names = Set.new([:@@value, "@@value"])
    calls = []
    instrumentation = Module.new do
      define_method(:class_variable_set) do |name, val|
        calls << [name, val] if cvar_names.include?(name)
        super(name, val)
      end
    end
    MattrWriterCountTest.singleton_class.prepend(instrumentation)

    # Warm the cvar so the writer hits the steady-state path (cvar already
    # defined). Both the buggy and the fixed code must call set exactly
    # once here.
    MattrWriterCountTest.value = :warm
    calls.clear

    MattrWriterCountTest.value = :one

    assert_equal 1, calls.size,
      "expected exactly 1 class_variable_set(@@value) call, got #{calls.size}: #{calls.inspect}"
  ensure
    MattrWriterCountTest.value = :initial
  end

  it "calls class_variable_set exactly once on the first write (cvar not yet defined)" do
    # Fresh module: the cvar is set by mattr_accessor's default-seeding
    # super call, so by the time our writer runs the cvar IS defined.
    # To exercise the "undefined" branch we remove the cvar first.
    MattrWriterCountTest.send(:remove_class_variable, :@@value) \
      if MattrWriterCountTest.class_variable_defined?(:@@value)

    cvar_names = Set.new([:@@value, "@@value"])
    calls = []
    instrumentation = Module.new do
      define_method(:class_variable_set) do |name, val|
        calls << [name, val] if cvar_names.include?(name)
        super(name, val)
      end
    end
    MattrWriterCountTest.singleton_class.prepend(instrumentation)

    MattrWriterCountTest.value = :first

    assert_equal 1, calls.size,
      "expected exactly 1 class_variable_set(@@value) call on first write, got #{calls.size}: #{calls.inspect}"
  ensure
    MattrWriterCountTest.value = :initial
  end
end