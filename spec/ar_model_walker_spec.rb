# frozen_string_literal: true

# Specs for Issue #16: extract ARModelWalker role (POODR §6 Modules & Roles).
# Four call sites independently enumerate `[ActiveRecord::Base] +
# (ActiveRecord::Base.descendants rescue [])` with slightly different
# per-class guards and error handling. ARModelWalker centralizes the walk:
#   - no-op when ActiveRecord::Base is not defined
#   - yields ActiveRecord::Base itself, then each descendant exactly once
#   - rescues per-class failures via RactorRailsShim._swallow so one bad
#     model does not abort the walk
#   - exposes an `each_model(skip_abstract:)` flag for the warming/freezing
#     cases that need to skip abstract classes (CacheWarmer) vs. the cases
#     that must NOT skip them (ClassIvarFreezer, attribute-method warming)
#
# Run: bundle exec ruby -Ilib -Ispec spec/ar_model_walker_spec.rb

require "minitest/autorun"
require "stringio"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ARModelWalkerSpec < Minitest::Spec
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

  # Set up a fake `::ActiveRecord` module with a `Base` whose `descendants`
  # returns the given list. Tears down cleanly: restores the prior ::ActiveRecord
  # state (undefined, or its original Base) so tests do not pollute each other.
  def with_fake_ar(descendants = [])
    had_ar = Object.const_defined?(:ActiveRecord)
    prev_ar = had_ar ? ::ActiveRecord : nil
    had_base = had_ar && prev_ar.const_defined?(:Base, false)
    prev_base = had_base ? prev_ar.const_get(:Base, false) : nil

    fake_ar = had_ar ? prev_ar : Module.new
    Object.const_set(:ActiveRecord, fake_ar) unless had_ar
    prev_ar&.send(:remove_const, :Base) if had_base
    fake_base = Class.new
    fake_ar.const_set(:Base, fake_base)
    fake_base.instance_variable_set(:@__descendants, descendants)
    def fake_base.descendants; @__descendants; end

    yield fake_base
  ensure
    fake_ar.send(:remove_const, :Base) if fake_ar.const_defined?(:Base, false)
    if had_base
      fake_ar.const_set(:Base, prev_base)
    elsif had_ar
      # had AR but no Base — leave Base removed (original state)
    else
      Object.send(:remove_const, :ActiveRecord)
    end
  end

  # --- existence + namespace ---

  it "ARModelWalker is a Module under RactorRailsShim" do
    assert_kind_of Module, RactorRailsShim::ARModelWalker
  end

  it "ARModelWalker responds to each_model" do
    assert_respond_to RactorRailsShim::ARModelWalker, :each_model
  end

  # --- no-op when AR is absent ---

  it "each_model is a no-op (yields nothing) when ActiveRecord is not defined" do
    prev = Object.const_defined?(:ActiveRecord) ? ::ActiveRecord : nil
    Object.send(:remove_const, :ActiveRecord) if prev
    yielded = []
    count = RactorRailsShim::ARModelWalker.each_model { |k| yielded << k }
    assert_empty yielded
    assert_equal 0, count
  ensure
    Object.const_set(:ActiveRecord, prev) if prev
  end

  # --- yields Base + descendants exactly once ---

  it "each_model yields Base itself, then each descendant exactly once" do
    a = Class.new
    b = Class.new
    with_fake_ar([a, b]) do |base|
      yielded = []
      RactorRailsShim::ARModelWalker.each_model { |k| yielded << k }
      assert_equal [base, a, b], yielded
    end
  end

  it "each_model yields Base even when descendants is empty" do
    with_fake_ar([]) do |base|
      yielded = []
      RactorRailsShim::ARModelWalker.each_model { |k| yielded << k }
      assert_equal [base], yielded
    end
  end

  # --- skip_abstract flag ---

  it "each_model(skip_abstract: true) skips abstract classes" do
    abstract = Class.new
    abstract.define_singleton_method(:abstract_class?) { true }
    concrete = Class.new
    with_fake_ar([abstract, concrete]) do |base|
      yielded = []
      RactorRailsShim::ARModelWalker.each_model(skip_abstract: true) { |k| yielded << k }
      assert_includes yielded, base
      assert_includes yielded, concrete
      refute_includes yielded, abstract
    end
  end

  it "each_model(skip_abstract: false) yields abstract classes too" do
    abstract = Class.new
    abstract.define_singleton_method(:abstract_class?) { true }
    with_fake_ar([abstract]) do |base|
      yielded = []
      RactorRailsShim::ARModelWalker.each_model(skip_abstract: false) { |k| yielded << k }
      assert_includes yielded, abstract
    end
  end

  it "each_model default (no kwarg) yields abstract classes" do
    abstract = Class.new
    abstract.define_singleton_method(:abstract_class?) { true }
    with_fake_ar([abstract]) do |base|
      yielded = []
      RactorRailsShim::ARModelWalker.each_model { |k| yielded << k }
      assert_includes yielded, abstract
    end
  end

  # --- per-class failure rescue ---

  it "each_model rescues per-class failures and continues to the next model" do
    good = Class.new
    bad = Class.new
    with_fake_ar([good, bad]) do |base|
      call_count = 0
      RactorRailsShim::ARModelWalker.each_model do |k|
        call_count += 1
        raise "boom on #{k.object_id}" if k == bad
      end
      # Base + good + bad all visited; bad raised but the walk continued.
      assert_equal 3, call_count
    end
  end

  it "each_model surfaces per-class failures through _swallow when debug=true" do
    bad = Class.new
    with_fake_ar([bad]) do |base|
      RactorRailsShim.debug = true
      out = capture_stderr do
        RactorRailsShim::ARModelWalker.each_model { |k| raise "boom" if k == bad }
      end
      assert_includes out, "[ractor_rails_shim]"
    end
  ensure
    RactorRailsShim.debug = false
  end

  # --- descendants rescue ---

  it "each_model treats a raising descendants method as empty (rescue)" do
    with_fake_ar([]) do |base|
      # Override descendants to raise on the instance we set up.
      base.define_singleton_method(:descendants) { raise StandardError, "boom" }
      yielded = []
      RactorRailsShim::ARModelWalker.each_model { |k| yielded << k }
      # Base is still yielded; the descendants rescue yields nothing extra.
      assert_equal [base], yielded
    end
  end

  # --- return value ---

  it "each_model returns the count of yielded models" do
    a = Class.new
    b = Class.new
    with_fake_ar([a, b]) do |base|
      count = RactorRailsShim::ARModelWalker.each_model { |_| }
      assert_equal 3, count
    end
  end

  it "each_model returns 0 when ActiveRecord is absent" do
    prev = Object.const_defined?(:ActiveRecord) ? ::ActiveRecord : nil
    Object.send(:remove_const, :ActiveRecord) if prev
    count = RactorRailsShim::ARModelWalker.each_model { |_| }
    assert_equal 0, count
  ensure
    Object.const_set(:ActiveRecord, prev) if prev
  end
end