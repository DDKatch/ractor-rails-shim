# frozen_string_literal: true

# Specs for Issue #13, Step 13.1: extract ConstantShareabilizer from the
# RactorRailsShim god module (POODR §1 SRP). The constant-shareability
# machinery — make_constant_shareable!, split_const_path, _safe_const_get,
# _make_value_shareable, install_shareable_constants, _apply_shareable_constants!,
# shareable_constants — is one role collapsed onto the singleton. These specs
# pin the extracted object's contract directly so it is independently specable.
#
# The RactorRailsShim facade keeps delegating methods (preserved by
# naming_convention_spec.rb / shim_spec.rb / safe_const_get_spec.rb /
# make_value_shareable_spec.rb), so those suites keep passing unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/constant_shareabilizer_spec.rb

require "minitest/autorun"
require "monitor"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

SC = RactorRailsShim.singleton_class
NoOpLock = SC.const_get(:NoOpLock)

class ConstantShareabilizerSpec < Minitest::Spec
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

  # --- namespace ---

  it "RactorRailsShim::ConstantShareabilizer is a Module" do
    assert_kind_of Module, RactorRailsShim::ConstantShareabilizer
  end

  # --- make_shareable! (was make_constant_shareable) ---

  it "make_shareable! deep-freezes an unshareable constant value" do
    mod = Module.new
    Object.const_set(:ShimCSMod, mod)
    mod.const_set(:LIST, ["a", "b"])
    refute Ractor.shareable?(mod::LIST)

    RactorRailsShim::ConstantShareabilizer.make_shareable!("ShimCSMod::LIST")

    assert Ractor.shareable?(mod::LIST)
    assert mod::LIST.frozen?
    assert mod::LIST.first.frozen?, "elements should be frozen (deep)"
  ensure
    Object.send(:remove_const, :ShimCSMod) if defined?(ShimCSMod)
  end

  it "make_shareable! is a no-op for an already-shareable constant" do
    mod = Module.new
    Object.const_set(:ShimCSShareable, mod)
    val = Ractor.make_shareable(["x"].freeze)
    mod.const_set(:LIST, val)

    RactorRailsShim::ConstantShareabilizer.make_shareable!("ShimCSShareable::LIST")

    assert_same val, mod.const_get(:LIST, false)
  ensure
    Object.send(:remove_const, :ShimCSShareable) if defined?(ShimCSShareable)
  end

  it "make_shareable! returns false for a missing constant path" do
    assert_equal false, RactorRailsShim::ConstantShareabilizer.make_shareable!("NonexistentCS::Thing")
  end

  it "make_shareable! returns true for a missing leaf (parent defined, leaf not)" do
    mod = Module.new
    Object.const_set(:ShimCSLeaf, mod)
    # Leaf "MISSING" not defined → treated as resolved (nothing to do).
    assert_equal true, RactorRailsShim::ConstantShareabilizer.make_shareable!("ShimCSLeaf::MISSING")
  ensure
    Object.send(:remove_const, :ShimCSLeaf) if defined?(ShimCSLeaf)
  end

  # --- make_value_shareable (was _make_value_shareable) ---

  it "make_value_shareable returns a shareable NoOpLock for a Monitor" do
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(Monitor.new)
    assert_kind_of NoOpLock, result
    assert Ractor.shareable?(result)
  end

  it "make_value_shareable returns a shareable NoOpLock for a Mutex" do
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(Mutex.new)
    assert_kind_of NoOpLock, result
    assert Ractor.shareable?(result)
  end

  it "make_value_shareable returns a shareable sentinel Symbol for a BasicObject" do
    basic = Class.new(BasicObject).new
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(basic)
    assert_kind_of Symbol, result
    assert result.frozen?
    assert Ractor.shareable?(result)
  end

  it "make_value_shareable returns nil (via _swallow) for an intrinsically unshareable Proc" do
    RactorRailsShim.debug = false
    out = capture_stderr do
      assert_nil RactorRailsShim::ConstantShareabilizer.make_value_shareable(->(*) { :x })
    end
    assert_empty out, "no stderr when debug? is false"
  ensure
    RactorRailsShim.debug = false
  end

  it "make_value_shareable funnels failures through _swallow (labeled, debug=true)" do
    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim::ConstantShareabilizer.make_value_shareable(->(*) { :x })
    end
    assert_includes out, "[ractor_rails_shim]"
    assert_match(/make_value_shareable/i, out)
  ensure
    RactorRailsShim.debug = false
  end

  it "make_value_shareable does not raise on a BasicObject lacking is_a?" do
    basic = Class.new(BasicObject).new
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(basic)
    assert Ractor.shareable?(result)
  end

  it "make_value_shareable deep-freezes a plain mutable value" do
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(["a", "b"])
    assert Ractor.shareable?(result)
    assert result.frozen?
  end

  # --- safe_const_get (was _safe_const_get) ---

  it "safe_const_get resolves a top-level constant" do
    assert_equal Object, RactorRailsShim::ConstantShareabilizer.safe_const_get("Object")
  end

  it "safe_const_get resolves a nested constant path" do
    assert_equal ActiveSupport::IsolatedExecutionState,
                 RactorRailsShim::ConstantShareabilizer.safe_const_get("ActiveSupport::IsolatedExecutionState")
  end

  it "safe_const_get returns nil for a missing constant" do
    assert_nil RactorRailsShim::ConstantShareabilizer.safe_const_get("NonexistentCSModule")
  end

  it "safe_const_get with inherit: false does NOT find inherited constants" do
    sub = Module.new { const_set(:CHILD, 42) }
    child = Module.new { include sub }
    child.const_set(:MINE, 99)
    Object.const_set(:InheritTestCS, child) unless Object.const_defined?(:InheritTestCS)
    begin
      assert_nil RactorRailsShim::ConstantShareabilizer.safe_const_get("InheritTestCS::CHILD", inherit: false),
                 "inherit: false must not resolve inherited constants"
    ensure
      Object.send(:remove_const, :InheritTestCS)
    end
  end

  # --- split_const_path ---

  it "split_const_path returns [Object, :Foo] for a top-level path" do
    owner, name = RactorRailsShim::ConstantShareabilizer.split_const_path("Object")
    assert_equal Object, owner
    assert_equal :Object, name
  end

  it "split_const_path returns [parent, :leaf] for a nested path" do
    owner, name = RactorRailsShim::ConstantShareabilizer.split_const_path("ActiveSupport::IsolatedExecutionState")
    assert_equal ActiveSupport, owner
    assert_equal :IsolatedExecutionState, name
  end

  it "split_const_path returns [nil, nil] when the parent isn't defined" do
    owner, name = RactorRailsShim::ConstantShareabilizer.split_const_path("NonexistentCS::Child::Grandchild")
    assert_nil owner
    assert_nil name
  end

  # --- apply! idempotency (Issue #24: flag lives on ConstantShareabilizer, not the facade) ---

  it "ConstantShareabilizer responds to applied? and reset_applied!" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :applied?
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :reset_applied!
  end

  it "apply! is idempotent via ConstantShareabilizer.@applied (not the facade)" do
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    saved = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    RactorRailsShim::SHAREABLE_CONSTANTS.replace([]) # vacuous: all resolve → flag sets

    refute RactorRailsShim::ConstantShareabilizer.applied?,
           "setup: flag should be unset before first run"

    RactorRailsShim::ConstantShareabilizer.apply!

    assert RactorRailsShim::ConstantShareabilizer.applied?,
           "flag should be truthy after first run"
  ensure
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(saved) if saved
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  it "apply! leaves the done flag unset when a constant is missing (retriable)" do
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    saved = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["DefinitelyMissingCS::Thing"])

    RactorRailsShim::ConstantShareabilizer.apply!

    refute RactorRailsShim::ConstantShareabilizer.applied?,
           "flag should stay unset so a later call retries the now-loadable constants"
  ensure
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(saved) if saved
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  # --- install / shareable_constants reader ---

  it "shareable_constants returns SHAREABLE_CONSTANTS" do
    assert_same RactorRailsShim::SHAREABLE_CONSTANTS,
                RactorRailsShim::ConstantShareabilizer.shareable_constants
  end

  # --- Facade delegation ---

  it "RactorRailsShim.make_constant_shareable! delegates to ConstantShareabilizer.make_shareable!" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:make_shareable!)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_shareable!) do |path|
      delegated = true
      original.call(path)
    end
    RactorRailsShim.make_constant_shareable!("Object")
    assert delegated, "facade should delegate to ConstantShareabilizer.make_shareable!"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_shareable!, original)
  end

  it "RactorRailsShim._make_value_shareable delegates to ConstantShareabilizer.make_value_shareable" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:make_value_shareable)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_value_shareable) do |v|
      delegated = true
      original.call(v)
    end
    RactorRailsShim._make_value_shareable(["a"])
    assert delegated, "facade should delegate to ConstantShareabilizer.make_value_shareable"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_value_shareable, original)
  end

  it "RactorRailsShim._safe_const_get delegates to ConstantShareabilizer.safe_const_get" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:safe_const_get)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:safe_const_get) do |path, **kw|
      delegated = true
      original.call(path, **kw)
    end
    RactorRailsShim._safe_const_get("Object")
    assert delegated, "facade should delegate to ConstantShareabilizer.safe_const_get"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:safe_const_get, original)
  end

  it "RactorRailsShim.split_const_path delegates to ConstantShareabilizer.split_const_path" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:split_const_path)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:split_const_path) do |path|
      delegated = true
      original.call(path)
    end
    RactorRailsShim.split_const_path("Object")
    assert delegated, "facade should delegate to ConstantShareabilizer.split_const_path"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:split_const_path, original)
  end

  it "RactorRailsShim._apply_shareable_constants! delegates to ConstantShareabilizer.apply!" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:apply!)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:apply!) do
      delegated = true
      original.call
    end
    RactorRailsShim.send(:_apply_shareable_constants!)
    assert delegated, "facade should delegate to ConstantShareabilizer.apply!"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:apply!, original)
  end

  it "RactorRailsShim.shareable_constants delegates to ConstantShareabilizer.shareable_constants" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:shareable_constants)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:shareable_constants) do
      delegated = true
      original.call
    end
    RactorRailsShim.shareable_constants
    assert delegated, "facade should delegate to ConstantShareabilizer.shareable_constants"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:shareable_constants, original)
  end

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # ConstantShareabilizer must be constructible with the collaborators it
  # currently reaches through the RactorRailsShim facade by global name:
  #   - `funnel`                    (= `_swallow`)
  #   - `register_patch`            (= `_register_patch`)
  #   - `introspectable`            (= `_introspectable?`, a callable predicate)
  #   - `noop_lock_class`           (= `NoOpLogDev`-style class for Mutex/Monitor)
  #   - `shareable_constants_registry` (= `SHAREABLE_CONSTANTS` array)
  # The seam is `configure(...)`; the defaults are the facade lookups so
  # existing call sites keep working. The `@applied`
  # idempotency flag stays on the facade singleton here — Issue #24 moves
  # it onto this role.

  it "responds to configure" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :configure
  end

  it "responds to reset_configuration" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :reset_configuration
  end

  it "responds to funnel" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :funnel
  end

  it "responds to register_patch" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :register_patch
  end

  it "responds to introspectable" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :introspectable
  end

  it "responds to noop_lock_class" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :noop_lock_class
  end

  it "responds to shareable_constants_registry" do
    assert_respond_to RactorRailsShim::ConstantShareabilizer, :shareable_constants_registry
  end

  it "make_value_shareable funnels through an injected funnel (labeled)" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::ConstantShareabilizer.configure(funnel: funnel)
    RactorRailsShim::ConstantShareabilizer.make_value_shareable(->(*) { :x })
    refute_empty funneled
    assert_match(/make_value_shareable/i, funneled.first)
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end

  it "make_value_shareable uses an injected noop_lock_class for a Mutex" do
    fake_lock_class = Class.new
    RactorRailsShim::ConstantShareabilizer.configure(
      noop_lock_class: fake_lock_class,
      introspectable: ->(v) { true }
    )
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(Mutex.new)
    assert_kind_of fake_lock_class, result, "Mutex should yield an instance of the injected lock class"
    assert Ractor.shareable?(result), "injected lock instance should be made shareable"
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end

  it "make_value_shareable uses an injected introspectable predicate" do
    # introspectable returns false → both branches short-circuit; the
    # BasicObject/sentinel branch fires (no #freeze) and yields a Symbol.
    RactorRailsShim::ConstantShareabilizer.configure(
      introspectable: ->(v) { false }
    )
    result = RactorRailsShim::ConstantShareabilizer.make_value_shareable(["a"])
    # Non-introspectable per the injected predicate → sentinel Symbol path.
    assert_kind_of Symbol, result
    assert Ractor.shareable?(result)
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end

  it "install registers via an injected register_patch" do
    registered = []
    register = ->(name, ver) { registered << [name, ver] }
    RactorRailsShim::ConstantShareabilizer.configure(register_patch: register)
    # Suppress the apply! side-effect by stubbing ActiveSupport undefined.
    had_as = Object.const_defined?(:ActiveSupport)
    prev_as = had_as ? ::ActiveSupport : nil
    Object.send(:remove_const, :ActiveSupport) if had_as
    RactorRailsShim::ConstantShareabilizer.install
    assert_includes registered.map(&:first), :shareable_constants
  ensure
    Object.const_set(:ActiveSupport, prev_as) if had_as
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end

  it "apply! iterates an injected shareable_constants_registry" do
    # Set up a real constant path the role can resolve + make shareable.
    mod = Module.new
    Object.const_set(:ShimCSInject, mod)
    mod.const_set(:LIST, ["a", "b"])
    fake_registry = ["ShimCSInject::LIST"]
    RactorRailsShim::ConstantShareabilizer.configure(
      shareable_constants_registry: fake_registry
    )
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    refute Ractor.shareable?(mod::LIST), "setup: LIST should start unshareable"

    RactorRailsShim::ConstantShareabilizer.apply!

    # apply! iterated the injected registry (not the facade constant) and
    # made our injected constant shareable.
    assert Ractor.shareable?(mod::LIST), "injected-registry constant should be made shareable"
    # The done flag set because every path resolved.
    assert RactorRailsShim::ConstantShareabilizer.applied?,
           "done flag should be set when all injected paths resolve"
  ensure
    Object.send(:remove_const, :ShimCSInject) if defined?(ShimCSInject)
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults" do
    RactorRailsShim::ConstantShareabilizer.configure(
      funnel: ->(label, &blk) { blk&.call },
      register_patch: ->(n, v) { },
      introspectable: ->(v) { true },
      noop_lock_class: Class.new,
      shareable_constants_registry: []
    )
    refute_equal RactorRailsShim::Funnel.method(:swallow), RactorRailsShim::ConstantShareabilizer.funnel
    refute_equal RactorRailsShim.method(:_register_patch), RactorRailsShim::ConstantShareabilizer.register_patch
    refute_equal RactorRailsShim.method(:_introspectable?), RactorRailsShim::ConstantShareabilizer.introspectable
    refute_equal NoOpLock, RactorRailsShim::ConstantShareabilizer.noop_lock_class
    refute_same RactorRailsShim::SHAREABLE_CONSTANTS, RactorRailsShim::ConstantShareabilizer.shareable_constants_registry

    RactorRailsShim::ConstantShareabilizer.reset_configuration
    assert_equal RactorRailsShim::Funnel.method(:swallow), RactorRailsShim::ConstantShareabilizer.funnel
    assert_equal RactorRailsShim.method(:_register_patch), RactorRailsShim::ConstantShareabilizer.register_patch
    assert_equal RactorRailsShim.method(:_introspectable?), RactorRailsShim::ConstantShareabilizer.introspectable
    assert_equal NoOpLock, RactorRailsShim::ConstantShareabilizer.noop_lock_class
    assert_same RactorRailsShim::SHAREABLE_CONSTANTS, RactorRailsShim::ConstantShareabilizer.shareable_constants_registry
  ensure
    RactorRailsShim::ConstantShareabilizer.reset_configuration
  end
end