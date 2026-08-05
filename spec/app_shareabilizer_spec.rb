# frozen_string_literal: true

# Specs for the `RactorRailsShim::AppShareabilizer` role object
# (extracted from the facade god module in Step 22.6, Issue #22).
#
# `AppShareabilizer` is the orchestrator that composes the shareability
# pipeline: precompute → freeze ivars → warm routes → neutralize logger →
# replace procs → replace locks → make_shareable → build fallback.
#
# These specs target the role object directly — calling
# `AppShareabilizer.make_shareable!(app)` — pinning the orchestration
# order by stubbing the facade steps and recording which fire.
#
# Run: ruby -Ilib -Ispec spec/app_shareabilizer_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class AppShareabilizerSpec < Minitest::Spec
  # The role object exists and exposes the entry point.
  it "is a module under RactorRailsShim with a .make_shareable! method" do
    assert RactorRailsShim.const_defined?(:AppShareabilizer, false),
           "RactorRailsShim::AppShareabilizer should be defined"
    assert RactorRailsShim::AppShareabilizer.respond_to?(:make_shareable!),
           "AppShareabilizer.make_shareable! should be defined"
  end

  # The orchestration fires every step in the right order. We stub each
  # facade method to record its name; the recorded sequence must match
  # the documented pipeline order.
  it "fires the orchestration steps in the documented order" do
    called = []
    app = Object.new

    stub_facade_step(:_apply_shareable_constants!) { called << :apply_constants }
    stub_facade_step(:_install_all_framework_patches) { called << :install_patches }
    stub_facade_step(:_precompute_lazy_ivars) { |a| called << :precompute_lazy }
    stub_facade_step(:_precompute_propshaft!) { |a| called << :precompute_propshaft }
    stub_facade_step(:_generate_ar_attribute_methods!) { called << :generate_ar_attrs }
    stub_facade_step(:_warm_attribute_method_patterns!) { called << :warm_attr_patterns }
    stub_facade_step(:_freeze_declared_callbacks!) { called << :freeze_callbacks }
    stub_facade_step(:_freeze_shareable_class_ivars!) { called << :freeze_class_ivars }
    stub_facade_step(:_warm_journey_routes!) { called << :warm_routes }
    stub_facade_step(:_neutralize_logger_io!) { |a| called << :neutralize_logger }
    stub_facade_step(:_replace_unshareable_procs!) { |a| called << :replace_procs }
    stub_facade_step(:_replace_locks_and_concurrent_maps!) { |a| called << :replace_locks }
    stub_facade_step(:_build_shareable_fallback!) { called << :build_fallback }
    # Stub the @applied flag so _apply_shareable_constants!
    # fires once.
    RactorRailsShim::ConstantShareabilizer.reset_applied!

    # Stub Ractor.make_shareable to record + return the app unchanged.
    orig_ms = Ractor.method(:make_shareable)
    Ractor.define_singleton_method(:make_shareable) { |o| called << :make_shareable; o }
    RactorRailsShim::AppShareabilizer.make_shareable!(app)
    Ractor.define_singleton_method(:make_shareable, orig_ms)

    expected_order = %i[
      apply_constants install_patches precompute_lazy precompute_propshaft
      generate_ar_attrs warm_attr_patterns freeze_callbacks freeze_class_ivars
      warm_routes neutralize_logger replace_procs replace_locks make_shareable
      build_fallback
    ]
    assert_equal expected_order, called,
                 "orchestration steps must fire in the documented order"
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  # Returns the (now-frozen) app — Ruby freeze-style: same object.
  it "returns the same app object it received" do
    app = Object.new
    # Stub the heavy steps to no-ops so the test is hermetic.
    stub_facade_step(:_apply_shareable_constants!) { }
    stub_facade_step(:_install_all_framework_patches) { }
    stub_facade_step(:_precompute_lazy_ivars) { |a| }
    stub_facade_step(:_precompute_propshaft!) { |a| }
    stub_facade_step(:_generate_ar_attribute_methods!) { }
    stub_facade_step(:_warm_attribute_method_patterns!) { }
    stub_facade_step(:_freeze_declared_callbacks!) { }
    stub_facade_step(:_freeze_shareable_class_ivars!) { }
    stub_facade_step(:_warm_journey_routes!) { }
    stub_facade_step(:_neutralize_logger_io!) { |a| }
    stub_facade_step(:_replace_unshareable_procs!) { |a| }
    stub_facade_step(:_replace_locks_and_concurrent_maps!) { |a| }
    stub_facade_step(:_build_shareable_fallback!) { }
    RactorRailsShim::ConstantShareabilizer.reset_applied!; RactorRailsShim::ConstantShareabilizer.instance_variable_set(:@applied, true)
    orig_ms = Ractor.method(:make_shareable)
    Ractor.define_singleton_method(:make_shareable) { |o| o }
    result = RactorRailsShim::AppShareabilizer.make_shareable!(app)
    Ractor.define_singleton_method(:make_shareable, orig_ms)
    assert_same app, result, "should return the same app object"
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  # The facade delegates to the role object.
  it "facade make_app_shareable! delegates to the role object" do
    app = Object.new
    stub_facade_step(:_apply_shareable_constants!) { }
    stub_facade_step(:_install_all_framework_patches) { }
    stub_facade_step(:_precompute_lazy_ivars) { |a| }
    stub_facade_step(:_precompute_propshaft!) { |a| }
    stub_facade_step(:_generate_ar_attribute_methods!) { }
    stub_facade_step(:_warm_attribute_method_patterns!) { }
    stub_facade_step(:_freeze_declared_callbacks!) { }
    stub_facade_step(:_freeze_shareable_class_ivars!) { }
    stub_facade_step(:_warm_journey_routes!) { }
    stub_facade_step(:_neutralize_logger_io!) { |a| }
    stub_facade_step(:_replace_unshareable_procs!) { |a| }
    stub_facade_step(:_replace_locks_and_concurrent_maps!) { |a| }
    stub_facade_step(:_build_shareable_fallback!) { }
    RactorRailsShim::ConstantShareabilizer.reset_applied!; RactorRailsShim::ConstantShareabilizer.instance_variable_set(:@applied, true)
    orig_ms = Ractor.method(:make_shareable)
    Ractor.define_singleton_method(:make_shareable) { |o| o }
    result = RactorRailsShim.make_app_shareable!(app)
    Ractor.define_singleton_method(:make_shareable, orig_ms)
    assert_same app, result, "facade should return the same app"
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  private

  # Stub a private facade method for the duration of the test. The stub
  # is restored in the teardown via @stubbed_origins. Accepts the method
  # name and a block that receives the same args the facade method would.
  def stub_facade_step(name, &blk)
    @stubbed_origins ||= {}
    @stubbed_origins[name] = RactorRailsShim.method(name) unless @stubbed_origins.key?(name)
    RactorRailsShim.define_singleton_method(name, &blk)
  end

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # AppShareabilizer is the composition root that sequences 13 facade
  # methods. Each is a collaborator reached through the RactorRailsShim
  # facade by global name. The seam is `configure(...)` with 13 callable
  # kwargs + `make_shareable_fn`; the defaults are the facade lookups so
  # existing call sites keep working. The `@applied` gate
  # and `SHAREABLE_APP` stash stay on the facade singleton here —
  # Issue #24/#29 moves them.

  it "responds to configure and reset_configuration" do
    assert_respond_to RactorRailsShim::AppShareabilizer, :configure
    assert_respond_to RactorRailsShim::AppShareabilizer, :reset_configuration
  end

  it "configure injects all 13 pipeline steps + make_shareable_fn" do
    noop = ->(*) { }
    RactorRailsShim::AppShareabilizer.configure(
      apply_shareable_constants: noop,
      install_all_framework_patches: noop,
      precompute_lazy_ivars: noop,
      precompute_propshaft: noop,
      generate_ar_attribute_methods: noop,
      warm_attribute_method_patterns: noop,
      freeze_declared_callbacks: noop,
      freeze_shareable_class_ivars: noop,
      warm_journey_routes: noop,
      neutralize_logger_io: noop,
      replace_unshareable_procs: noop,
      replace_locks_and_concurrent_maps: noop,
      build_shareable_fallback: noop,
      make_shareable_fn: ->(o) { o },
      reassign_shareable_const: noop
    )
    # The readers return the injected callables.
    assert_equal noop, RactorRailsShim::AppShareabilizer.apply_shareable_constants
    assert_equal noop, RactorRailsShim::AppShareabilizer.build_shareable_fallback
    assert_equal noop, RactorRailsShim::AppShareabilizer.reassign_shareable_const
  ensure
    RactorRailsShim::AppShareabilizer.reset_configuration
  end

  it "make_shareable! routes through the injected pipeline steps (not the facade)" do
    called = []
    RactorRailsShim::AppShareabilizer.configure(
      apply_shareable_constants: -> { called << :apply_constants },
      install_all_framework_patches: -> { called << :install_patches },
      precompute_lazy_ivars: ->(a) { called << :precompute_lazy },
      precompute_propshaft: ->(a) { called << :precompute_propshaft },
      generate_ar_attribute_methods: -> { called << :generate_ar_attrs },
      warm_attribute_method_patterns: -> { called << :warm_attr_patterns },
      freeze_declared_callbacks: -> { called << :freeze_callbacks },
      freeze_shareable_class_ivars: -> { called << :freeze_class_ivars },
      warm_journey_routes: -> { called << :warm_routes },
      neutralize_logger_io: ->(a) { called << :neutralize_logger },
      replace_unshareable_procs: ->(a) { called << :replace_procs },
      replace_locks_and_concurrent_maps: ->(a) { called << :replace_locks },
      build_shareable_fallback: -> { called << :build_fallback },
      make_shareable_fn: ->(o) { called << :make_shareable; o },
      reassign_shareable_const: ->(s, v) { s }
    )
    RactorRailsShim::ConstantShareabilizer.reset_applied!; RactorRailsShim::ConstantShareabilizer.instance_variable_set(:@applied, true)
    app = Object.new
    RactorRailsShim::AppShareabilizer.make_shareable!(app)
    expected = %i[install_patches precompute_lazy precompute_propshaft
                  generate_ar_attrs warm_attr_patterns freeze_callbacks
                  freeze_class_ivars warm_routes neutralize_logger
                  replace_procs replace_locks make_shareable build_fallback]
    assert_equal expected, called
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    RactorRailsShim::AppShareabilizer.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults" do
    RactorRailsShim::AppShareabilizer.configure(
      apply_shareable_constants: ->(*) { },
      reassign_shareable_const: ->(s, v) { v }
    )
    refute_equal RactorRailsShim.method(:_apply_shareable_constants!),
                 RactorRailsShim::AppShareabilizer.apply_shareable_constants
    refute_equal RactorRailsShim.method(:_reassign_shareable_const),
                 RactorRailsShim::AppShareabilizer.reassign_shareable_const

    RactorRailsShim::AppShareabilizer.reset_configuration
    assert_equal RactorRailsShim.method(:_apply_shareable_constants!),
                 RactorRailsShim::AppShareabilizer.apply_shareable_constants
    assert_equal RactorRailsShim.method(:_reassign_shareable_const),
                 RactorRailsShim::AppShareabilizer.reassign_shareable_const
  ensure
    RactorRailsShim::AppShareabilizer.reset_configuration
  end

  private

  # Stub a private facade method for the duration of the test. The stub
  # is restored in the teardown via @stubbed_origins. Accepts the method
  # name and a block that receives the same args the facade method would.
  def stub_facade_step(name, &blk)
    @stubbed_origins ||= {}
    @stubbed_origins[name] = RactorRailsShim.method(name) unless @stubbed_origins.key?(name)
    RactorRailsShim.define_singleton_method(name, &blk)
  end

  # Restore all stubbed facade methods between tests so state doesn't leak.
  def teardown
    super
    @stubbed_origins&.each do |name, orig|
      RactorRailsShim.define_singleton_method(name, orig)
    end
    @stubbed_origins = nil
  end

  # --- Issue #29: make_app_shareable! interface fixes ---

  # Step 29.1: make_shareable! requires an explicit app argument
  it "make_shareable! requires an explicit app argument (no default)" do
    # Calling without arguments should raise ArgumentError
    assert_raises ArgumentError do
      RactorRailsShim::AppShareabilizer.make_shareable!
    end
  end

  # Step 29.2: stash! is a one-shot idempotent method
  it "AppShareabilizer.stash! stashes the app as SHAREABLE_APP" do
    app = Object.new
    RactorRailsShim::AppShareabilizer.reset_stashed!
    RactorRailsShim::AppShareabilizer.stash!(app)
    assert RactorRailsShim.const_defined?(:SHAREABLE_APP, false),
           "SHAREABLE_APP should be defined after stash!"
  ensure
    RactorRailsShim::AppShareabilizer.reset_stashed!
  end

  it "AppShareabilizer.stash! is idempotent (second call is a no-op)" do
    app1 = Object.new
    app2 = Object.new
    RactorRailsShim::AppShareabilizer.reset_stashed!
    RactorRailsShim::AppShareabilizer.stash!(app1)
    RactorRailsShim::AppShareabilizer.stash!(app2)
    # First stash wins — const_defined? guard
    assert RactorRailsShim.const_defined?(:SHAREABLE_APP, false)
  ensure
    RactorRailsShim::AppShareabilizer.reset_stashed!
  end

  it "AppShareabilizer.stashed? reflects the one-shot flag" do
    RactorRailsShim::AppShareabilizer.reset_stashed!
    refute RactorRailsShim::AppShareabilizer.stashed?
    RactorRailsShim::AppShareabilizer.stash!(Object.new)
    assert RactorRailsShim::AppShareabilizer.stashed?
  ensure
    RactorRailsShim::AppShareabilizer.reset_stashed!
  end
end