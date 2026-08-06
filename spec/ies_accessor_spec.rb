# frozen_string_literal: true

# Specs for IESAccessor (Issue #45): a module that generates reader/writer
# methods via the 3-tier IES lookup pattern. Extracts the repeated accessor
# pattern from patches/active_support.rb (20+ accessor patches that all
# follow the same shape).
#
# The generated methods use StorageStrategy for the actual lookup/store,
# so they inherit both Ractor-mode and Thread-mode behavior.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/patches"

class IESAccessorSpec < Minitest::Spec
  # A minimal target class to receive generated accessors.
  class AccessorTarget
    # Placeholder for generated methods.
  end

  # A frozen target to test the frozen-receiver path.
  class FrozenTarget
    # Placeholder for generated methods.
  end

  # Track keys we set so we can clean them up (Storage doesn't expose .keys).
  def storage_key_for(name)
    key = :"ractor_rails_shim_ies_accessor_test_#{name}"
    @used_keys ||= []
    @used_keys << key
    key
  end

  before do
    @used_keys = []
    @target = Class.new(AccessorTarget)
  end

  after do
    (@used_keys || []).each { |k| RactorRailsShim.storage.delete(k) }
  end

  # --- define_reader ---

  it "define_reader creates a reader method on the target" do
    key = storage_key_for(:reader_basic)
    RactorRailsShim::IESAccessor.define_reader(@target, :my_reader, key)
    assert @target.method_defined?(:my_reader),
           "target should have a :my_reader method after define_reader"
  end

  it "define_reader returns the value from IES when present" do
    key = storage_key_for(:reader_ies)
    RactorRailsShim.storage[key] = "from_ies"
    RactorRailsShim::IESAccessor.define_reader(@target, :ies_reader, key)
    obj = @target.new
    assert_equal "from_ies", obj.ies_reader
  end

  it "define_reader returns nil when IES and fallback are both empty (main ractor)" do
    key = storage_key_for(:reader_empty)
    RactorRailsShim::IESAccessor.define_reader(@target, :empty_reader, key)
    obj = @target.new
    assert_nil obj.empty_reader
  end

  # --- define_writer ---

  it "define_writer creates a writer method on the target" do
    key = storage_key_for(:writer_basic)
    RactorRailsShim::IESAccessor.define_writer(@target, :my_writer, key)
    assert @target.method_defined?(:my_writer=),
           "target should have a :my_writer= method after define_writer"
  end

  it "define_writer stores the value in IES" do
    key = storage_key_for(:writer_ies)
    RactorRailsShim::IESAccessor.define_writer(@target, :ies_writer, key)
    obj = @target.new
    obj.ies_writer = "hello"
    assert_equal "hello", RactorRailsShim.storage[key]
  end

  it "define_writer stores the value in CLASS_ATTR_VALUES when main ractor" do
    key = storage_key_for(:writer_class_attr)
    RactorRailsShim::IESAccessor.define_writer(@target, :ca_writer, key)
    obj = @target.new
    obj.ca_writer = 42
    assert_equal 42, RactorRailsShim::Registry.class_attr_values[key]
  end

  # --- define_accessor ---

  it "define_accessor creates both reader and writer" do
    key = storage_key_for(:accessor_both)
    RactorRailsShim::IESAccessor.define_accessor(@target, :both_accessor, key)
    obj = @target.new
    obj.both_accessor = "round-trip"
    assert_equal "round-trip", obj.both_accessor
  end

  # --- frozen receiver ---

  it "reader returns the default when receiver is frozen" do
    key = storage_key_for(:reader_frozen)
    frozen_obj = FrozenTarget.new.freeze
    # Define the reader AFTER freeze to test the frozen-receiver path.
    # The reader should not raise; it should handle the frozen case.
    RactorRailsShim::IESAccessor.define_reader(FrozenTarget, :frozen_reader, key)
    # On a frozen object, calling the reader should not raise.
    # The method is defined on the class, not the instance, so it works.
    result = frozen_obj.frozen_reader
    # When IES is empty and fallback is empty, result is nil.
    assert_nil result
  end

  # --- key format ---

  it "define_accessor uses the exact key symbol provided" do
    key = :"rrs_ies_accessor_exact_key_test"
    @used_keys << key
    RactorRailsShim::IESAccessor.define_accessor(@target, :exact_key, key)
    obj = @target.new
    obj.exact_key = "stored"
    assert_equal "stored", RactorRailsShim.storage[key]
  end

  # --- storage_strategy integration ---

  it "define_reader uses storage_strategy.lookup for the actual lookup" do
    key = storage_key_for(:reader_strategy)
    RactorRailsShim.storage[key] = "strategy_value"
    RactorRailsShim::IESAccessor.define_reader(@target, :strategy_reader, key)
    obj = @target.new
    # The value comes through the storage_strategy, not raw IES.
    assert_equal "strategy_value", obj.strategy_reader
  end
end
