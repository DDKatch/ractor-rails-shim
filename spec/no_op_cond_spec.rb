# frozen_string_literal: true

# Specs for Issue #11: replace NoOpLock#new_cond's anonymous
# `Struct.new(:wait, :signal, :broadcast).new(...)` with a named class.
#
# The POODR critique (CODE_REVIEW.md #11): the anonymous Struct is clever
# but obscure — a reader can't tell what the condvar contract is without
# grepping for the property names. A named class (NoOpCond) makes the
# duck-typing shape explicit: it answers `wait`, `signal`, and `broadcast`
# as no-ops, matching the MonitorMixin::ConditionVariable-like API that
# Rails code expects from `lock.new_cond`.
#
# Contract pinned:
#   1. NoOpLock#new_cond returns a NoOpCond instance (named class, not
#      anonymous Struct).
#   2. NoOpCond answers wait / signal / broadcast, each a no-op (returns
#      nil or self, never raises).
#   3. NoOpCond instances are shareable after make_shareable (the whole
#      point of NoOpLock — a shareable stand-in for an unshareable Mutex).
#   4. The named class is reachable on RactorRailsShim's singleton class
#      (same access path as NoOpLock), so other specs/code can reference it.
#
# Run: bundle exec ruby -Ilib -Ispec spec/no_op_cond_spec.rb

require "minitest/autorun"
require "ractor_rails_shim/patches"

class NoOpCondSpec < Minitest::Spec
  SC = RactorRailsShim.singleton_class
  NoOpLock = SC.const_get(:NoOpLock)

  it "NoOpCond is a named class on RactorRailsShim's singleton class" do
    assert SC.const_defined?(:NoOpCond, false),
      "NoOpCond should be a named class on RactorRailsShim singleton class"
    assert_kind_of Class, SC.const_get(:NoOpCond),
      "NoOpCond should be a Class, not an anonymous Struct"
  end

  it "NoOpLock#new_cond returns a NoOpCond instance" do
    cond = NoOpLock.new.new_cond
    assert_kind_of SC.const_get(:NoOpCond), cond,
      "new_cond should return a NoOpCond instance, not an anonymous Struct"
  end

  it "NoOpCond#wait is a no-op (returns nil, never raises)" do
    cond = NoOpLock.new.new_cond
    assert_nil cond.wait
  end

  it "NoOpCond#signal is a no-op (returns nil, never raises)" do
    cond = NoOpLock.new.new_cond
    assert_nil cond.signal
  end

  it "NoOpCond#broadcast is a no-op (returns nil, never raises)" do
    cond = NoOpLock.new.new_cond
    assert_nil cond.broadcast
  end

  it "NoOpCond#wait accepts an optional timeout arg without raising" do
    cond = NoOpLock.new.new_cond
    assert_nil cond.wait(0.1)
  end

  it "a frozen NoOpCond is Ractor-shareable" do
    cond = NoOpLock.new.new_cond
    cond.freeze
    assert Ractor.shareable?(cond),
      "NoOpCond should be Ractor-shareable when frozen (it's a NoOpLock collaborator)"
  end

  it "NoOpCond is NOT a Struct subclass (named class, not anonymous Struct)" do
    refute SC.const_get(:NoOpCond).ancestors.any? { |a| a.is_a?(::Struct) },
      "NoOpCond should be a plain class, not a Struct subclass"
  end
end