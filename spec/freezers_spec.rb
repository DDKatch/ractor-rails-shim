# frozen_string_literal: true

# Specs for the extracted Freezers sub-domain (Issue #1: decompose the
# RactorRailsShim god module). The freeze/warm steps that prepare the
# shareable graph live as private _freeze_*! / _warm_*! methods on the
# RactorRailsShim singleton. Per POODR they are five distinct responsibilities
# collapsed onto one object; each is extracted into its own object under
# RactorRailsShim::Freezers::* so it is independently specable, while the
# RactorRailsShim facade keeps delegating methods for backward compatibility.
#
# This spec asserts the extracted objects are reachable through their own
# namespace (not only through the singleton facade) and that the observable
# behaviour matches the original methods.
#
# Run: bundle exec ruby -Ilib -Ispec spec/freezers_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class FreezersSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  # --- CacheWarmer: module existence + namespace ---

  it "RactorRailsShim::Freezers is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers
  end

  it "RactorRailsShim::Freezers::CacheWarmer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::CacheWarmer
  end

  # --- CacheWarmer: behaviour ---

  it "CacheWarmer.call is a no-op when ActiveRecord::Base is not defined" do
    # ActiveRecord is not loaded under the shim's own bundle; the call must
    # not raise and must return a truthy value (it ran).
    assert RactorRailsShim::Freezers::CacheWarmer.call
  end

  it "CacheWarmer.call warms each non-abstract model's lazily-computed caches" do
    # Stub a minimal ActiveRecord::Base with one concrete + one abstract
    # descendant. The warmer methods record calls so we can assert which
    # class had which method warmed.
    fake_ar = Module.new
    Object.const_set(:FakeARBase, fake_ar) unless defined?(FakeARBase)
    called = {}
    warmer_methods = RactorRailsShim::Freezers::CacheWarmer::WARMER_METHODS

    # Make FakeARBase look like AR::Base for the duration of the test:
    # define .descendants and the warmer methods as recorders.
    def fake_ar.descendants; [FakeARConcrete, FakeARAbstract]; end
    warmer_methods.each do |m|
      fake_ar.define_singleton_method(m) { called[:FakeARBase] ||= []; called[:FakeARBase] << m }
    end

    concrete = Class.new
    Object.const_set(:FakeARConcrete, concrete)
    concrete.define_singleton_method(:abstract_class?) { false }
    warmer_methods.each do |m|
      concrete.define_singleton_method(m) { called[:FakeARConcrete] ||= []; called[:FakeARConcrete] << m }
    end

    abstract = Class.new
    Object.const_set(:FakeARAbstract, abstract)
    abstract.define_singleton_method(:abstract_class?) { true }
    warmer_methods.each do |m|
      abstract.define_singleton_method(m) { called[:FakeARAbstract] ||= []; called[:FakeARAbstract] << m }
    end

    # Stub defined?(::ActiveRecord::Base) by aliasing. The method checks
    # `defined?(::ActiveRecord::Base)` directly; we can't fake that without
    # defining ActiveRecord. Instead, define a minimal ::ActiveRecord::Base
    # that points at our fake, then remove it.
    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    RactorRailsShim::Freezers::CacheWarmer.call

    # FakeARBase (the base itself) is always warmed (no abstract_class? guard
    # on the base — only on descendants).
    assert_includes called.keys, :FakeARBase, "base class warmers should be called"
    # Concrete descendant warmed.
    assert_includes called.keys, :FakeARConcrete, "concrete descendant warmers should be called"
    # Abstract descendant skipped.
    refute_includes called.keys, :FakeARAbstract, "abstract descendant should be skipped"
    # Every warmer method was invoked on the concrete model.
    assert_equal warmer_methods.sort, called[:FakeARConcrete].sort
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase) if defined?(FakeARBase)
    Object.send(:remove_const, :FakeARConcrete) if defined?(FakeARConcrete)
    Object.send(:remove_const, :FakeARAbstract) if defined?(FakeARAbstract)
  end

  it "CacheWarmer.call funnels warmer failures through _swallow (labeled)" do
    # A warmer method that raises should be swallowed, not propagated. Under
    # debug=true the failure should surface with the CacheWarmer label.
    fake_ar = Module.new
    Object.const_set(:FakeARBase2, fake_ar) unless defined?(FakeARBase2)
    def fake_ar.descendants; []; end
    def fake_ar.timestamp_attributes_for_create_in_model
      raise RuntimeError, "forced-warmer-failure"
    end
    # Other warmers are no-ops.
    (RactorRailsShim::Freezers::CacheWarmer::WARMER_METHODS - [:timestamp_attributes_for_create_in_model]).each do |m|
      fake_ar.define_singleton_method(m) {}
    end

    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    RactorRailsShim.debug = true
    out = capture_stderr do
      # Must not raise.
      RactorRailsShim::Freezers::CacheWarmer.call
    end
    assert_includes out, "[ractor_rails_shim]", "warmer failure should funnel through _swallow"
    assert_match(/warmer|cache/i, out, "stderr should carry a cache-warmer label")
  ensure
    RactorRailsShim.debug = false
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase2) if defined?(FakeARBase2)
  end

  # --- Facade delegation: RactorRailsShim._warm_active_record_class_caches! ---

  it "RactorRailsShim._warm_active_record_class_caches! delegates to CacheWarmer.call" do
    # The facade method must still exist and delegate. Verify by stubbing
    # CacheWarmer.call to record the delegation.
    delegated = false
    original = RactorRailsShim::Freezers::CacheWarmer.method(:call)
    RactorRailsShim::Freezers::CacheWarmer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim._warm_active_record_class_caches!
    assert delegated, "facade should delegate to CacheWarmer.call"
  ensure
    RactorRailsShim::Freezers::CacheWarmer.define_singleton_method(:call, original)
  end
end