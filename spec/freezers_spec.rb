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

  # --- ClassIvarFreezer: AR model class-ivar freezing ---

  it "RactorRailsShim::Freezers::ClassIvarFreezer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::ClassIvarFreezer
  end

  it "ClassIvarFreezer.call is a no-op when ActiveRecord::Base is not defined" do
    assert RactorRailsShim::Freezers::ClassIvarFreezer.call
  end

  it "ClassIvarFreezer.call makes unshareable AR model class-ivars shareable" do
    # Build a fake AR::Base with one model whose class ivar holds an unshareable
    # Hash. After the call, the ivar value must be Ractor.shareable?.
    fake_ar = Module.new
    Object.const_set(:FakeARBase3, fake_ar) unless defined?(FakeARBase3)
    def fake_ar.descendants; [FakeARModel3]; end

    model = Class.new
    Object.const_set(:FakeARModel3, model)
    model.instance_variable_set(:@unshareable_cache, { a: 1 })
    refute Ractor.shareable?(model.instance_variable_get(:@unshareable_cache))

    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    RactorRailsShim::Freezers::ClassIvarFreezer.call

    val = model.instance_variable_get(:@unshareable_cache)
    assert Ractor.shareable?(val), "model class ivar should be shareable after freeze"
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase3) if defined?(FakeARBase3)
    Object.send(:remove_const, :FakeARModel3) if defined?(FakeARModel3)
  end

  it "ClassIvarFreezer.call does NOT skip abstract classes (workers recurse into them)" do
    # The comment in the original method is load-bearing: abstract classes like
    # ApplicationRecord are recursed into by workers, so their ivars must also
    # be shareable. Pin that abstract classes are NOT skipped.
    fake_ar = Module.new
    Object.const_set(:FakeARBase4, fake_ar) unless defined?(FakeARBase4)
    def fake_ar.descendants; [FakeARAbstract4]; end

    abstract = Class.new
    Object.const_set(:FakeARAbstract4, abstract)
    abstract.define_singleton_method(:abstract_class?) { true }
    abstract.instance_variable_set(:@abstract_cache, { b: 2 })
    refute Ractor.shareable?(abstract.instance_variable_get(:@abstract_cache))

    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    RactorRailsShim::Freezers::ClassIvarFreezer.call

    val = abstract.instance_variable_get(:@abstract_cache)
    assert Ractor.shareable?(val), "abstract class ivar should also be shareable"
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase4) if defined?(FakeARBase4)
    Object.send(:remove_const, :FakeARAbstract4) if defined?(FakeARAbstract4)
  end

  it "ClassIvarFreezer.call skips ivars that are already shareable" do
    fake_ar = Module.new
    Object.const_set(:FakeARBase5, fake_ar) unless defined?(FakeARBase5)
    def fake_ar.descendants; []; end
    fake_ar.instance_variable_set(:@already_shareable, Ractor.make_shareable({ x: 1 }))

    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    # Must not raise; already-shareable values are left as-is.
    RactorRailsShim::Freezers::ClassIvarFreezer.call
    assert Ractor.shareable?(fake_ar.instance_variable_get(:@already_shareable))
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase5) if defined?(FakeARBase5)
  end

  it "ClassIvarFreezer.call funnels freeze failures through _swallow (labeled)" do
    # A class ivar whose value can't be made shareable should be swallowed,
    # not propagated. Under debug=true the failure surfaces with the label.
    fake_ar = Module.new
    Object.const_set(:FakeARBase6, fake_ar) unless defined?(FakeARBase6)
    def fake_ar.descendants; []; end
    # A Proc is intrinsically unshareable; Ractor.make_shareable raises.
    fake_ar.instance_variable_set(:@unfreezable, ->(*) { :x })

    ar_module = Module.new
    Object.const_set(:ActiveRecord, ar_module) unless defined?(::ActiveRecord)
    ar_module.const_set(:Base, fake_ar) unless ar_module.const_defined?(:Base, false)

    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim::Freezers::ClassIvarFreezer.call
    end
    assert_includes out, "[ractor_rails_shim]", "freeze failure should funnel through _swallow"
    assert_match(/freeze AR ivar/i, out, "stderr should carry the AR-ivar-freeze label")
  ensure
    RactorRailsShim.debug = false
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord) && ar_module
    Object.send(:remove_const, :FakeARBase6) if defined?(FakeARBase6)
  end

  it "RactorRailsShim._freeze_active_record_class_ivars! delegates to ClassIvarFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::ClassIvarFreezer.method(:call)
    RactorRailsShim::Freezers::ClassIvarFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim._freeze_active_record_class_ivars!
    assert delegated, "facade should delegate to ClassIvarFreezer.call"
  ensure
    RactorRailsShim::Freezers::ClassIvarFreezer.define_singleton_method(:call, original)
  end

  # --- GlobalClassIvarFreezer: global class-ivar freezing (Time/Date/I18n) ---

  it "RactorRailsShim::Freezers::GlobalClassIvarFreezer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::GlobalClassIvarFreezer
  end

  it "GlobalClassIvarFreezer.call makes unshareable global class-ivars shareable" do
    # Use a real global class (Time) — set a temporary unshareable ivar, freeze,
    # then verify it's shareable and clean up. Time is always defined.
    Time.instance_variable_set(:@_shim_test_global_ivar, { tz: "UTC" })
    refute Ractor.shareable?(Time.instance_variable_get(:@_shim_test_global_ivar))

    RactorRailsShim::Freezers::GlobalClassIvarFreezer.call

    val = Time.instance_variable_get(:@_shim_test_global_ivar)
    assert Ractor.shareable?(val), "global class ivar should be shareable after freeze"
  ensure
    Time.remove_instance_variable(:@_shim_test_global_ivar) rescue nil
  end

  it "GlobalClassIvarFreezer.call skips already-shareable global ivars" do
    Time.instance_variable_set(:@_shim_test_shareable_ivar, Ractor.make_shareable({ x: 1 }))
    # Must not raise; already-shareable values are left as-is.
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.call
    assert Ractor.shareable?(Time.instance_variable_get(:@_shim_test_shareable_ivar))
  ensure
    Time.remove_instance_variable(:@_shim_test_shareable_ivar) rescue nil
  end

  it "GlobalClassIvarFreezer.call funnels freeze failures through _swallow (labeled)" do
    Time.instance_variable_set(:@_shim_test_unfreezable, ->(*) { :x })
    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim::Freezers::GlobalClassIvarFreezer.call
    end
    assert_includes out, "[ractor_rails_shim]", "freeze failure should funnel through _swallow"
    assert_match(/freeze global ivar/i, out, "stderr should carry the global-ivar-freeze label")
  ensure
    RactorRailsShim.debug = false
    Time.remove_instance_variable(:@_shim_test_unfreezable) rescue nil
  end

  it "RactorRailsShim._freeze_global_class_ivars! delegates to GlobalClassIvarFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::GlobalClassIvarFreezer.method(:call)
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim._freeze_global_class_ivars!
    assert delegated, "facade should delegate to GlobalClassIvarFreezer.call"
  ensure
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.define_singleton_method(:call, original)
  end
end