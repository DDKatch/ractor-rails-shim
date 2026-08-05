# frozen_string_literal: true

# Specs for the `StorageStrategy` role (Issue #15): a composed strategy that
# replaces the `if thread_mode?` branch in `class_attribute.rb` (and later
# `active_support.rb` / `installer.rb`). Two implementations share one
# contract:
#
#   * `StorageStrategy::Ractor` — direct `RactorRailsShim.storage` lookup +
#     `SHAREABLE_FALLBACK` (the current `_class_attr_ractor_methods` body).
#   * `StorageStrategy::Thread`  — ancestor-walk + `CLASS_ATTR_VALUES` (the
#     current `_class_attr_thread_methods` body).
#
# Both implement `lookup(owner, key, missing_default)` and
# `store(owner, key, value)`. `class_attribute.rb` emits ONE heredoc that
# calls `RactorRailsShim.storage_strategy.lookup(...)` — the two-mode branch
# collapses to one body.
#
# `RactorRailsShim.storage_strategy` is selected once at install from
# `RunMode.thread?`.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/patches"

class StorageStrategySpec < Minitest::Spec
  # Use a fresh plain class for each test to avoid cross-test key collisions.
  # The strategies don't require the owner to define class_attribute — they
  # only use `owner.ancestors` (Thread) or ignore `owner` (Ractor, key is fixed).
  def fresh_owner
    Class.new
  end

  # --- Both strategies implement the same contract ---

  [RactorRailsShim::StorageStrategy::Ractor,
   RactorRailsShim::StorageStrategy::Thread].each do |strategy|
    describe strategy.name do
      it "implements lookup and store" do
        assert_respond_to strategy, :lookup
        assert_respond_to strategy, :store
      end

      it "store then lookup round-trips a value" do
        owner = fresh_owner
        key = :"rrs_strategy_test_#{owner.object_id}"
        strategy.store(owner, key, "v")
        assert_equal "v", strategy.lookup(owner, key, "nil")
      end

      it "lookup returns the missing default when the slot is empty" do
        owner = fresh_owner
        key = :"rrs_strategy_missing_#{owner.object_id}"
        # The missing_default arg is a Ruby source string, so it evaluates
        # to the literal value (nil here).
        assert_nil strategy.lookup(owner, key, "nil")
        assert_equal "fallback", strategy.lookup(owner, key, '"fallback"')
      end

      it "store overwrites an existing value" do
        owner = fresh_owner
        key = :"rrs_strategy_overwrite_#{owner.object_id}"
        strategy.store(owner, key, 1)
        strategy.store(owner, key, 2)
        assert_equal 2, strategy.lookup(owner, key, "nil")
      end
    end
  end

  # --- Thread strategy: ancestor walk ---

  describe RactorRailsShim::StorageStrategy::Thread do
    it "lookup walks ancestors for copy-on-write fallback (subclass finds superclass value)" do
      parent = Class.new
      child  = Class.new(parent)
      # The key the writer uses: ractor_rails_shim_class_attr_<oid>___class_attr_probe
      key = :"ractor_rails_shim_class_attr_#{parent.object_id}___class_attr_probe"
      RactorRailsShim::StorageStrategy::Thread.store(parent, key, "from-parent")
      # child.lookup with the PARENT's key should find it via ancestor walk
      assert_equal "from-parent",
                   RactorRailsShim::StorageStrategy::Thread.lookup(child, key, "nil")
    end
  end

  # --- Ractor strategy: SHAREABLE_FALLBACK ---

  describe RactorRailsShim::StorageStrategy::Ractor do
    it "lookup returns the IES value when the slot is present (fallback not consulted)" do
      owner = fresh_owner
      key = :"rrs_strategy_present_#{owner.object_id}"
      RactorRailsShim::StorageStrategy::Ractor.store(owner, key, "ies-value")
      assert_equal "ies-value",
                   RactorRailsShim::StorageStrategy::Ractor.lookup(owner, key, "nil")
    end

    it "lookup returns the missing default when neither IES nor fallback has the key" do
      owner = fresh_owner
      key = :"rrs_strategy_nothing_#{owner.object_id}"
      RactorRailsShim.storage.delete(key) if RactorRailsShim.storage.key?(key)
      refute RactorRailsShim::SHAREABLE_FALLBACK.key?(key)
      assert_nil RactorRailsShim::StorageStrategy::Ractor.lookup(owner, key, "nil")
      assert_equal "d", RactorRailsShim::StorageStrategy::Ractor.lookup(owner, key, '"d"')
    end
  end

  # --- Selection: RactorRailsShim.storage_strategy ---

  it "storage_strategy is set by install based on RunMode" do
    # After install (run by other specs in this process), storage_strategy
    # is either Ractor or Thread depending on the resolved run mode. Pin
    # that it's one of the two and matches RunMode.thread?.
    s = RactorRailsShim.storage_strategy
    assert_includes [RactorRailsShim::StorageStrategy::Ractor,
                     RactorRailsShim::StorageStrategy::Thread], s
    expected = RactorRailsShim::RunMode.thread? ?
      RactorRailsShim::StorageStrategy::Thread :
      RactorRailsShim::StorageStrategy::Ractor
    assert_equal expected, s
  end
end