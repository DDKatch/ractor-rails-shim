# frozen_string_literal: true

# Specs for Issue #13, Step 13.1: extract ConstantShareabilizer from the
# RactorRailsShim god module (POODR §1 SRP). The constant-shareability
# machinery — make_constant_shareable, split_const_path, _safe_const_get,
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

  # --- make_shareable (was make_constant_shareable) ---

  it "make_shareable deep-freezes an unshareable constant value" do
    mod = Module.new
    Object.const_set(:ShimCSMod, mod)
    mod.const_set(:LIST, ["a", "b"])
    refute Ractor.shareable?(mod::LIST)

    RactorRailsShim::ConstantShareabilizer.make_shareable("ShimCSMod::LIST")

    assert Ractor.shareable?(mod::LIST)
    assert mod::LIST.frozen?
    assert mod::LIST.first.frozen?, "elements should be frozen (deep)"
  ensure
    Object.send(:remove_const, :ShimCSMod) if defined?(ShimCSMod)
  end

  it "make_shareable is a no-op for an already-shareable constant" do
    mod = Module.new
    Object.const_set(:ShimCSShareable, mod)
    val = Ractor.make_shareable(["x"].freeze)
    mod.const_set(:LIST, val)

    RactorRailsShim::ConstantShareabilizer.make_shareable("ShimCSShareable::LIST")

    assert_same val, mod.const_get(:LIST, false)
  ensure
    Object.send(:remove_const, :ShimCSShareable) if defined?(ShimCSShareable)
  end

  it "make_shareable returns false for a missing constant path" do
    assert_equal false, RactorRailsShim::ConstantShareabilizer.make_shareable("NonexistentCS::Thing")
  end

  it "make_shareable returns true for a missing leaf (parent defined, leaf not)" do
    mod = Module.new
    Object.const_set(:ShimCSLeaf, mod)
    # Leaf "MISSING" not defined → treated as resolved (nothing to do).
    assert_equal true, RactorRailsShim::ConstantShareabilizer.make_shareable("ShimCSLeaf::MISSING")
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

  # --- apply! (was _apply_shareable_constants!) ---

  it "apply! is idempotent via @shareable_constants_done" do
    RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
    saved = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    RactorRailsShim::SHAREABLE_CONSTANTS.replace([]) # vacuous: all resolve → flag sets

    refute RactorRailsShim.instance_variable_get(:@shareable_constants_done),
           "setup: flag should be unset before first run"

    RactorRailsShim::ConstantShareabilizer.apply!

    assert RactorRailsShim.instance_variable_defined?(:@shareable_constants_done),
           "flag should be defined after first run"
    assert RactorRailsShim.instance_variable_get(:@shareable_constants_done),
           "flag should be truthy after first run"
  ensure
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(saved) if saved
    RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
  end

  it "apply! leaves the done flag unset when a constant is missing (retriable)" do
    RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
    saved = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["DefinitelyMissingCS::Thing"])

    RactorRailsShim::ConstantShareabilizer.apply!

    refute RactorRailsShim.instance_variable_get(:@shareable_constants_done),
           "flag should stay unset so a later call retries the now-loadable constants"
  ensure
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(saved) if saved
    RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
  end

  # --- install / shareable_constants reader ---

  it "shareable_constants returns SHAREABLE_CONSTANTS" do
    assert_same RactorRailsShim::SHAREABLE_CONSTANTS,
                RactorRailsShim::ConstantShareabilizer.shareable_constants
  end

  # --- Facade delegation ---

  it "RactorRailsShim.make_constant_shareable delegates to ConstantShareabilizer.make_shareable" do
    delegated = false
    original = RactorRailsShim::ConstantShareabilizer.method(:make_shareable)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_shareable) do |path|
      delegated = true
      original.call(path)
    end
    RactorRailsShim.make_constant_shareable("Object")
    assert delegated, "facade should delegate to ConstantShareabilizer.make_shareable"
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:make_shareable, original)
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
end