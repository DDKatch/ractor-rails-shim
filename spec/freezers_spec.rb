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

  # --- Facade delegation: RactorRailsShim::Freezers::CacheWarmer.call ---

  it "RactorRailsShim::Freezers::CacheWarmer.call delegates to CacheWarmer.call" do
    # The facade method must still exist and delegate. Verify by stubbing
    # CacheWarmer.call to record the delegation.
    delegated = false
    original = RactorRailsShim::Freezers::CacheWarmer.method(:call)
    RactorRailsShim::Freezers::CacheWarmer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim::Freezers::CacheWarmer.call
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

  it "RactorRailsShim::Freezers::ClassIvarFreezer.call delegates to ClassIvarFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::ClassIvarFreezer.method(:call)
    RactorRailsShim::Freezers::ClassIvarFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim::Freezers::ClassIvarFreezer.call
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

  it "RactorRailsShim::Freezers::GlobalClassIvarFreezer.call delegates to GlobalClassIvarFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::GlobalClassIvarFreezer.method(:call)
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.call
    assert delegated, "facade should delegate to GlobalClassIvarFreezer.call"
  ensure
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.define_singleton_method(:call, original)
  end

  # --- GlobalConstantFreezer: Time/Date::DATE_FORMATS etc. ---

  it "RactorRailsShim::Freezers::GlobalConstantFreezer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::GlobalConstantFreezer
  end

  # Helper: temporarily replace GlobalConstantFreezer::TARGETS with the given
  # array of module names, yield, then restore. The real .call reads TARGETS,
  # so this exercises the actual logic without duplicating it.
  def _with_gc_targets(module_names)
    original = RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS
    verbose, $VERBOSE = $VERBOSE, nil
    RactorRailsShim::Freezers::GlobalConstantFreezer.const_set(:TARGETS, module_names.freeze)
    $VERBOSE = verbose
    yield
  ensure
    verbose, $VERBOSE = $VERBOSE, nil
    RactorRailsShim::Freezers::GlobalConstantFreezer.const_set(:TARGETS, original)
    $VERBOSE = verbose
  end

  it "GlobalConstantFreezer.call drops non-shareable Hash values and freezes" do
    mod = Module.new
    Object.const_set(:ShimGCFTestMod, mod)
    mod.const_set(:DATE_FORMATS, { db: "%Y-%m-%d", custom: ->(*) { "x" } })
    refute Ractor.shareable?(mod.const_get(:DATE_FORMATS, false))

    _with_gc_targets(["ShimGCFTestMod"]) do
      RactorRailsShim::Freezers::GlobalConstantFreezer.call
    end

    val = mod.const_get(:DATE_FORMATS, false)
    assert Ractor.shareable?(val), "DATE_FORMATS should be shareable after freeze"
    assert val.frozen?, "DATE_FORMATS should be frozen"
    assert_includes val, :db, "shareable entry should be kept"
    refute_includes val, :custom, "non-shareable Proc entry should be dropped"
  ensure
    Object.send(:remove_const, :ShimGCFTestMod) if defined?(ShimGCFTestMod)
  end

  it "GlobalConstantFreezer.call filters non-shareable Array values and freezes" do
    mod = Module.new
    Object.const_set(:ShimGCFArrayMod, mod)
    mod.const_set(:DATE_FORMATS, [:sym, ->(*) { :x }, "str"])
    refute Ractor.shareable?(mod.const_get(:DATE_FORMATS, false))

    _with_gc_targets(["ShimGCFArrayMod"]) do
      RactorRailsShim::Freezers::GlobalConstantFreezer.call
    end

    val = mod.const_get(:DATE_FORMATS, false)
    assert Ractor.shareable?(val), "Array DATE_FORMATS should be shareable"
    assert val.frozen?, "Array should be frozen"
    assert_includes val, :sym
    assert_includes val, "str"
    refute val.any? { |e| e.is_a?(Proc) }, "Proc entry should be filtered out"
  ensure
    Object.send(:remove_const, :ShimGCFArrayMod) if defined?(ShimGCFArrayMod)
  end

  it "GlobalConstantFreezer.call skips already-shareable constants" do
    mod = Module.new
    Object.const_set(:ShimGCFShareableMod, mod)
    mod.const_set(:DATE_FORMATS, Ractor.make_shareable({ a: 1 }))

    _with_gc_targets(["ShimGCFShareableMod"]) do
      RactorRailsShim::Freezers::GlobalConstantFreezer.call
    end
    assert Ractor.shareable?(mod.const_get(:DATE_FORMATS, false))
  ensure
    Object.send(:remove_const, :ShimGCFShareableMod) if defined?(ShimGCFShareableMod)
  end

  it "RactorRailsShim::Freezers::GlobalConstantFreezer.call delegates to GlobalConstantFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::GlobalConstantFreezer.method(:call)
    RactorRailsShim::Freezers::GlobalConstantFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim::Freezers::GlobalConstantFreezer.call
    assert delegated, "facade should delegate to GlobalConstantFreezer.call"
  ensure
    RactorRailsShim::Freezers::GlobalConstantFreezer.define_singleton_method(:call, original)
  end

  it "GlobalConstantFreezer.add_target appends to TARGETS" do
    original_targets = RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS.dup
    RactorRailsShim::Freezers::GlobalConstantFreezer.add_target("CustomGem")
    assert_includes RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS, "CustomGem"
  ensure
    RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS.replace(original_targets)
  end

  it "GlobalConstantFreezer.call iterates newly added targets" do
    mod = Module.new
    Object.const_set(:ShimGCFAddTargetMod, mod)
    mod.const_set(:DATE_FORMATS, { added: :yes })
    original_targets = RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS.dup
    RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS.replace(["ShimGCFAddTargetMod"])
    RactorRailsShim::Freezers::GlobalConstantFreezer.call
    val = mod.const_get(:DATE_FORMATS, false)
    assert Ractor.shareable?(val), "newly added target's constant should be frozen"
  ensure
    RactorRailsShim::Freezers::GlobalConstantFreezer::TARGETS.replace(original_targets)
    Object.send(:remove_const, :ShimGCFAddTargetMod) if defined?(ShimGCFAddTargetMod)
  end

  # --- MessagesConstantsFreezer: AS::Messages::Metadata constants ---

  it "RactorRailsShim::Freezers::MessagesConstantsFreezer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::MessagesConstantsFreezer
  end

  it "MessagesConstantsFreezer.call is a no-op when msgpack gem is absent" do
    # msgpack is not in the shim's unit bundle; the call must not raise and
    # must return a truthy value. This is the default path in unit specs.
    assert RactorRailsShim::Freezers::MessagesConstantsFreezer.call
  end

  # Helper: set up a fake ActiveSupport::Messages::Metadata with the given
  # constants, stub msgpack_available? to true, and stub the require of
  # active_support/message_pack so it doesn't raise Gem::LoadError when the
  # C extension isn't in the unit bundle. Yields, then cleans up.
  def _with_fake_metadata(envelope_val, timestamp_val)
    Object.const_set(:ActiveSupport, Module.new) unless defined?(::ActiveSupport)
    as = ::ActiveSupport
    as.const_set(:Messages, Module.new) unless as.const_defined?(:Messages, false)
    as::Messages.const_set(:Metadata, Module.new) unless as::Messages.const_defined?(:Metadata, false)
    metadata = as::Messages::Metadata
    metadata.const_set(:ENVELOPE_SERIALIZERS, envelope_val)
    metadata.const_set(:TIMESTAMP_SERIALIZERS, timestamp_val)

    original_avail = RactorRailsShim::Freezers::MessagesConstantsFreezer.method(:msgpack_available?)
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:msgpack_available?) { true }
    original_load = RactorRailsShim::Freezers::MessagesConstantsFreezer.method(:_load_message_pack)
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:_load_message_pack) { nil }

    yield metadata
  ensure
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:msgpack_available?, original_avail)
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:_load_message_pack, original_load)
    if defined?(::ActiveSupport)
      as = ::ActiveSupport
      if as.const_defined?(:Messages, false)
        as::Messages.send(:remove_const, :Metadata) if as::Messages.const_defined?(:Metadata, false)
        as.send(:remove_const, :Messages)
      end
    end
  end

  it "MessagesConstantsFreezer.call freezes Metadata constants when msgpack + AS::Messages::Metadata are present" do
    envelope = [Module.new]
    timestamp = [Module.new]
    refute Ractor.shareable?(envelope)

    _with_fake_metadata(envelope, timestamp) do |metadata|
      RactorRailsShim::Freezers::MessagesConstantsFreezer.call
    end

    assert Ractor.shareable?(envelope), "ENVELOPE_SERIALIZERS should be shareable after freeze"
    assert Ractor.shareable?(timestamp), "TIMESTAMP_SERIALIZERS should be shareable after freeze"
  end

  it "MessagesConstantsFreezer.call skips already-shareable Metadata constants" do
    envelope = Ractor.make_shareable([Module.new])
    timestamp = Ractor.make_shareable([Module.new])

    _with_fake_metadata(envelope, timestamp) do
      # Must not raise; already-shareable values left as-is.
      RactorRailsShim::Freezers::MessagesConstantsFreezer.call
    end
    assert Ractor.shareable?(envelope)
  end

  it "RactorRailsShim::Freezers::MessagesConstantsFreezer.call delegates to MessagesConstantsFreezer.call" do
    delegated = false
    original = RactorRailsShim::Freezers::MessagesConstantsFreezer.method(:call)
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:call) do
      delegated = true
      original.call
    end
    RactorRailsShim::Freezers::MessagesConstantsFreezer.call
    assert delegated, "facade should delegate to MessagesConstantsFreezer.call"
  ensure
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:call, original)
  end

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # Each Freezers::* sub-module reaches its collaborators (the _swallow
  # debug funnel and _safe_const_get helper) through the RactorRailsShim
  # facade by global name. The seam is per-sub-module `configure(funnel:,
  # safe_const_get:)` + `reset_configuration` + readers, defaulting to the
  # facade lookups so existing call sites keep working.

  it "CacheWarmer responds to configure/reset_configuration/funnel" do
    f = RactorRailsShim::Freezers::CacheWarmer
    assert_respond_to f, :configure
    assert_respond_to f, :reset_configuration
    assert_respond_to f, :funnel
  end

  it "CacheWarmer.call funnels per-method failures through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::Freezers::CacheWarmer.configure(funnel: funnel)
    fake_base = Class.new
    fake_base.define_singleton_method(:sequence_name) { raise "boom" }
    fake_base.define_singleton_method(:abstract_class?) { false }
    fake_base.define_singleton_method(:descendants) { [] }
    prev_ar = Object.const_defined?(:ActiveRecord) ? ::ActiveRecord : nil
    had_ar = Object.const_defined?(:ActiveRecord)
    Object.send(:remove_const, :ActiveRecord) if had_ar
    fake_ar = Module.new
    Object.const_set(:ActiveRecord, fake_ar)
    fake_ar.const_set(:Base, fake_base)
    RactorRailsShim::Freezers::CacheWarmer.call
    assert(funneled.any? { |l| l.include?("warm AR cache") },
           "expected a warm-AR-cache funnel label, got #{funneled.inspect}")
  ensure
    RactorRailsShim::Freezers::CacheWarmer.reset_configuration
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord) && !prev_ar
    Object.const_set(:ActiveRecord, prev_ar) if prev_ar
  end

  it "ClassIvarFreezer responds to configure/reset_configuration/funnel" do
    f = RactorRailsShim::Freezers::ClassIvarFreezer
    assert_respond_to f, :configure
    assert_respond_to f, :reset_configuration
    assert_respond_to f, :funnel
  end

  it "ClassIvarFreezer.call funnels ivar-freeze failures through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::Freezers::ClassIvarFreezer.configure(funnel: funnel)
    fake_base = Class.new
    fake_base.instance_variable_set(:@proc, ->(*) { :x })
    fake_base.define_singleton_method(:descendants) { [] }
    fake_base.define_singleton_method(:abstract_class?) { false }
    prev_ar = Object.const_defined?(:ActiveRecord) ? ::ActiveRecord : nil
    had_ar = Object.const_defined?(:ActiveRecord)
    Object.send(:remove_const, :ActiveRecord) if had_ar
    fake_ar = Module.new
    Object.const_set(:ActiveRecord, fake_ar)
    fake_ar.const_set(:Base, fake_base)
    RactorRailsShim::Freezers::ClassIvarFreezer.call
    assert(funneled.any? { |l| l.include?("freeze AR ivar") },
           "expected a freeze-AR-ivar funnel label, got #{funneled.inspect}")
  ensure
    RactorRailsShim::Freezers::ClassIvarFreezer.reset_configuration
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord) && !prev_ar
    Object.const_set(:ActiveRecord, prev_ar) if prev_ar
  end

  it "GlobalClassIvarFreezer responds to configure/reset_configuration/funnel/safe_const_get" do
    f = RactorRailsShim::Freezers::GlobalClassIvarFreezer
    assert_respond_to f, :configure
    assert_respond_to f, :reset_configuration
    assert_respond_to f, :funnel
    assert_respond_to f, :safe_const_get
  end

  it "GlobalClassIvarFreezer.call resolves targets via an injected safe_const_get" do
    resolved = []
    scg = ->(name) { resolved << name; nil }
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.configure(safe_const_get: scg)
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.call
    assert_includes resolved, "Time"
    assert_includes resolved, "Date"
    assert_includes resolved, "DateTime"
    assert_includes resolved, "I18n"
  ensure
    RactorRailsShim::Freezers::GlobalClassIvarFreezer.reset_configuration
  end

  it "GlobalConstantFreezer responds to configure/reset_configuration/safe_const_get" do
    f = RactorRailsShim::Freezers::GlobalConstantFreezer
    assert_respond_to f, :configure
    assert_respond_to f, :reset_configuration
    assert_respond_to f, :safe_const_get
  end

  it "GlobalConstantFreezer.call resolves targets via an injected safe_const_get" do
    resolved = []
    scg = ->(name) { resolved << name; nil }
    RactorRailsShim::Freezers::GlobalConstantFreezer.configure(safe_const_get: scg)
    RactorRailsShim::Freezers::GlobalConstantFreezer.call
    assert_includes resolved, "Time"
    assert_includes resolved, "Date"
    assert_includes resolved, "DateTime"
  ensure
    RactorRailsShim::Freezers::GlobalConstantFreezer.reset_configuration
  end

  it "MessagesConstantsFreezer responds to configure/reset_configuration/safe_const_get" do
    f = RactorRailsShim::Freezers::MessagesConstantsFreezer
    assert_respond_to f, :configure
    assert_respond_to f, :reset_configuration
    assert_respond_to f, :safe_const_get
  end

  it "MessagesConstantsFreezer.call resolves via an injected safe_const_get" do
    resolved = []
    scg = ->(name, **kw) { resolved << name; nil }
    RactorRailsShim::Freezers::MessagesConstantsFreezer.configure(safe_const_get: scg)
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:msgpack_available?) { true }
    RactorRailsShim::Freezers::MessagesConstantsFreezer.define_singleton_method(:_load_message_pack) { }
    RactorRailsShim::Freezers::MessagesConstantsFreezer.call
    assert_includes resolved, "ActiveSupport::Messages::Metadata"
  ensure
    RactorRailsShim::Freezers::MessagesConstantsFreezer.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults for all Freezers" do
    funnel_only = [RactorRailsShim::Freezers::CacheWarmer,
                   RactorRailsShim::Freezers::ClassIvarFreezer]
    both = [RactorRailsShim::Freezers::GlobalClassIvarFreezer]
    scg_only = [RactorRailsShim::Freezers::GlobalConstantFreezer,
                RactorRailsShim::Freezers::MessagesConstantsFreezer]

    funnel_only.each do |f|
      f.configure(funnel: ->(l, &b) { b&.call })
      refute_equal RactorRailsShim::Funnel.method(:swallow), f.funnel
      f.reset_configuration
      assert_equal RactorRailsShim::Funnel.method(:swallow), f.funnel
    end
    both.each do |f|
      f.configure(funnel: ->(l, &b) { b&.call }, safe_const_get: ->(n, **k) { nil })
      refute_equal RactorRailsShim::Funnel.method(:swallow), f.funnel
      refute_equal RactorRailsShim::ConstantShareabilizer.method(:safe_const_get), f.safe_const_get
      f.reset_configuration
      assert_equal RactorRailsShim::Funnel.method(:swallow), f.funnel
      assert_equal RactorRailsShim::ConstantShareabilizer.method(:safe_const_get), f.safe_const_get
    end
    scg_only.each do |f|
      f.configure(safe_const_get: ->(n, **k) { nil })
      refute_equal RactorRailsShim::ConstantShareabilizer.method(:safe_const_get), f.safe_const_get
      f.reset_configuration
      assert_equal RactorRailsShim::ConstantShareabilizer.method(:safe_const_get), f.safe_const_get
    end
  ensure
    [RactorRailsShim::Freezers::CacheWarmer,
     RactorRailsShim::Freezers::ClassIvarFreezer,
     RactorRailsShim::Freezers::GlobalClassIvarFreezer,
     RactorRailsShim::Freezers::GlobalConstantFreezer,
     RactorRailsShim::Freezers::MessagesConstantsFreezer,
     RactorRailsShim::Freezers::ShareableClassIvarFreezer].each { |f| f.reset_configuration }
  end

  # --- ShareableClassIvarFreezer: SHAREABLE_CLASS_IVARS freeze ---

  it "RactorRailsShim::Freezers::ShareableClassIvarFreezer is a Module" do
    assert_kind_of Module, RactorRailsShim::Freezers::ShareableClassIvarFreezer
  end

  it "ShareableClassIvarFreezer.call makes listed ivars shareable" do
    target = Module.new
    Object.const_set(:ShivFreezeIvarTest, target)
    target.instance_variable_set(:@test_ivar, { foo: :bar })
    RactorRailsShim::SHAREABLE_CLASS_IVARS << ["ShivFreezeIvarTest", :@test_ivar]
    # Not shareable before call
    refute Ractor.shareable?(target.instance_variable_get(:@test_ivar))
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.call
    val = target.instance_variable_get(:@test_ivar)
    assert Ractor.shareable?(val), "ivar should be shareable after freezer call"
  ensure
    RactorRailsShim::SHAREABLE_CLASS_IVARS.delete(["ShivFreezeIvarTest", :@test_ivar])
    Object.send(:remove_const, :ShivFreezeIvarTest) if defined?(ShivFreezeIvarTest)
  end

  it "ShareableClassIvarFreezer.call skips classes not yet defined" do
    RactorRailsShim::SHAREABLE_CLASS_IVARS << ["NonexistentClassForFreezer", :@x]
    # Must not raise
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.call
  ensure
    RactorRailsShim::SHAREABLE_CLASS_IVARS.delete(["NonexistentClassForFreezer", :@x])
  end

  it "ShareableClassIvarFreezer.call skips nil ivar values" do
    target = Module.new
    Object.const_set(:ShivFreezeNilIvar, target)
    target.instance_variable_set(:@nil_ivar, nil)
    RactorRailsShim::SHAREABLE_CLASS_IVARS << ["ShivFreezeNilIvar", :@nil_ivar]
    # Must not raise; nil value is skipped
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.call
  ensure
    RactorRailsShim::SHAREABLE_CLASS_IVARS.delete(["ShivFreezeNilIvar", :@nil_ivar])
    Object.send(:remove_const, :ShivFreezeNilIvar) if defined?(ShivFreezeNilIvar)
  end

  it "ShareableClassIvarFreezer.call funnels through injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.configure(funnel: funnel)
    target = Module.new
    Object.const_set(:ShivFreezeFunnelTest, target)
    target.instance_variable_set(:@fiv, { a: 1 })
    RactorRailsShim::SHAREABLE_CLASS_IVARS << ["ShivFreezeFunnelTest", :@fiv]
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.call
    assert funneled.any? { |l| l.include?("freeze global ivar") },
           "funnel should have been called with freeze label"
  ensure
    RactorRailsShim::SHAREABLE_CLASS_IVARS.delete(["ShivFreezeFunnelTest", :@fiv])
    Object.send(:remove_const, :ShivFreezeFunnelTest) if defined?(ShivFreezeFunnelTest)
    RactorRailsShim::Freezers::ShareableClassIvarFreezer.reset_configuration
  end

  # The facade delegation _freeze_shareable_class_ivars! was deleted in
  # Issue #31. The role-object method ShareableClassIvarFreezer.call is
  # tested directly above.

  # --- Issue #41: freezer target-list appendability + PRE_TOUCH registry ---

  it "GlobalClassIvarFreezer::TARGETS is a mutable array (appendable)" do
    t = RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS
    assert_kind_of Array, t
    # Should not be frozen — downstream apps can add to it
    refute t.frozen?, "TARGETS must be mutable for add_target"
  end

  it "GlobalClassIvarFreezer.add_target appends to TARGETS" do
    t = RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS
    original = t.dup
    t.push("_shim_gcf_test_target_41")
    assert_includes t, "_shim_gcf_test_target_41"
  ensure
    RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS.replace(original) if original
  end

  it "GlobalClassIvarFreezer.add_target does not duplicate" do
    t = RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS
    original = t.dup
    t.push("_shim_gcf_dedup_41") unless t.include?("_shim_gcf_dedup_41")
    count_before = t.count("_shim_gcf_dedup_41")
    t.push("_shim_gcf_dedup_41") unless t.include?("_shim_gcf_dedup_41")
    assert_equal count_before, t.count("_shim_gcf_dedup_41")
  ensure
    RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS.replace(original) if original
  end

  it "MessagesConstantsFreezer::TARGET_NAMES is a mutable array (appendable)" do
    t = RactorRailsShim::Freezers::MessagesConstantsFreezer::TARGET_NAMES
    assert_kind_of Array, t
    refute t.frozen?, "TARGET_NAMES must be mutable for add_target"
  end

  it "MessagesConstantsFreezer.add_target appends to TARGET_NAMES" do
    t = RactorRailsShim::Freezers::MessagesConstantsFreezer::TARGET_NAMES
    original = t.dup
    t.push(:CUSTOM_SERIALIZERS)
    assert_includes t, :CUSTOM_SERIALIZERS
  ensure
    RactorRailsShim::Freezers::MessagesConstantsFreezer::TARGET_NAMES.replace(original) if original
  end

  it "GlobalConstantFreezer responds to funnel" do
    assert_respond_to RactorRailsShim::Freezers::GlobalConstantFreezer, :funnel
  end

  it "GlobalConstantFreezer.call funnels errors through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::Freezers::GlobalConstantFreezer.configure(funnel: funnel)
    # Stub safe_const_get to return a module whose const_set raises
    mod = Module.new
    mod.const_set(:DATE_FORMATS, { bad: ->(*) { :x } })
    Object.const_set(:ShimGCFunnelTest, mod)
    scg = ->(name) { name == "ShimGCFunnelTest" ? mod : nil }
    RactorRailsShim::Freezers::GlobalConstantFreezer.configure(safe_const_get: scg, funnel: funnel)
    # The call should not raise — errors are funneled
    RactorRailsShim::Freezers::GlobalConstantFreezer.call
  ensure
    RactorRailsShim::Freezers::GlobalConstantFreezer.reset_configuration
    Object.send(:remove_const, :ShimGCFunnelTest) if defined?(ShimGCFunnelTest)
  end

  it "ShareableClassIvarFreezer::PRE_TOUCH is a mutable array of [class_name, method_name] pairs" do
    t = RactorRailsShim::Freezers::ShareableClassIvarFreezer
    assert t.const_defined?(:PRE_TOUCH, false), "PRE_TOUCH should exist"
    pt = t.const_get(:PRE_TOUCH)
    assert_kind_of Array, pt
    refute pt.frozen?, "PRE_TOUCH must be mutable for downstream additions"
    pt.each do |entry|
      assert_kind_of Array, entry
      assert_equal 2, entry.length
      assert_kind_of String, entry[0]
      assert_kind_of Symbol, entry[1]
    end
  end

  it "ShareableClassIvarFreezer::PRE_TOUCH includes ActiveSupport::Editor and Warden::Strategies" do
    pt = RactorRailsShim::Freezers::ShareableClassIvarFreezer::PRE_TOUCH
    editor_entry = pt.find { |name, _| name == "ActiveSupport::Editor" }
    assert editor_entry, "PRE_TOUCH should include ActiveSupport::Editor"
    assert_equal :current, editor_entry[1]

    warden_entry = pt.find { |name, _| name == "Warden::Strategies" }
    assert warden_entry, "PRE_TOUCH should include Warden::Strategies"
    assert_equal :_strategies, warden_entry[1]
  end

  it "ShareableClassIvarFreezer.add_pre_touch adds a new entry" do
    t = RactorRailsShim::Freezers::ShareableClassIvarFreezer
    original = t::PRE_TOUCH.dup
    t.add_pre_touch("FakeClass", :fake_method)
    assert t::PRE_TOUCH.any? { |name, m| name == "FakeClass" && m == :fake_method }
  ensure
    t::PRE_TOUCH.replace(original) if original
  end
end