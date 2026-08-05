# frozen_string_literal: true

# Specs for Issue #5: use the existing _introspectable? helper consistently
# instead of ad-hoc `rescue false` guards in _make_value_shareable.
#
# _make_value_shareable (core.rb) handles three cases:
#   1. Monitor/Mutex → NoOpLock (never contended post-boot, shareable)
#   2. BasicObject (no #freeze) → frozen Symbol sentinel (compared with equal?)
#   3. Everything else → deep-frozen via Ractor.make_shareable (funneled
#      through _swallow so a Proc/TypeMap failure surfaces under debug)
#
# The ad-hoc `(val.is_a?(::Monitor) rescue false)` / `(val.respond_to?(:freeze)
# rescue false)` guards existed because BasicObject subclasses don't define
# is_a?/respond_to? (Kernel not included). The existing _introspectable?
# helper (make_shareable.rb) already handles this safely — use it consistently.
#
# Run: bundle exec ruby -Ilib -Ispec spec/make_value_shareable_spec.rb

require "minitest/autorun"
require "monitor"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

SC = RactorRailsShim.singleton_class
NoOpLock = SC.const_get(:NoOpLock)

class MakeValueShareableSpec < Minitest::Spec
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

  # --- Monitor / Mutex → NoOpLock ---

  it "returns a shareable NoOpLock for a Monitor" do
    result = RactorRailsShim._make_value_shareable(Monitor.new)
    assert_kind_of NoOpLock, result
    assert Ractor.shareable?(result)
  end

  it "returns a shareable NoOpLock for a Mutex" do
    result = RactorRailsShim._make_value_shareable(Mutex.new)
    assert_kind_of NoOpLock, result
    assert Ractor.shareable?(result)
  end

  # --- BasicObject → sentinel Symbol ---

  it "returns a shareable sentinel Symbol for a BasicObject (no #freeze)" do
    basic = Class.new(BasicObject).new
    result = RactorRailsShim._make_value_shareable(basic)
    assert_kind_of Symbol, result
    assert result.frozen?, "sentinel Symbol should be frozen"
    assert Ractor.shareable?(result)
  end

  # --- Normal value → deep-frozen via make_shareable ---

  it "returns a shareable frozen value for a plain mutable object" do
    result = RactorRailsShim._make_value_shareable(["a", "b"])
    assert Ractor.shareable?(result)
    assert result.frozen?
  end

  it "returns nil (via _swallow) for an intrinsically unshareable value" do
    # A Proc can't be made shareable; make_shareable raises. The _swallow
    # funnel catches it and returns nil (silent by default).
    RactorRailsShim.debug = false
    out = capture_stderr do
      assert_nil RactorRailsShim._make_value_shareable(->(*) { :x })
    end
    assert_empty out, "no stderr when debug? is false"
  ensure
    RactorRailsShim.debug = false
  end

  it "funnels make_shareable failures through _swallow (labeled, debug=true)" do
    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim._make_value_shareable(->(*) { :x })
    end
    assert_includes out, "[ractor_rails_shim]"
    assert_match(/make_value_shareable/i, out)
  ensure
    RactorRailsShim.debug = false
  end

  # --- BasicObject without is_a? must NOT raise ---

  it "does not raise on a BasicObject that lacks is_a? (handled by _introspectable?)" do
    # A bare BasicObject has neither is_a? nor respond_to?. The ad-hoc rescue
    # guards handled this; the refactored version must use _introspectable?
    # and route a non-introspectable object to the sentinel (it can't be a
    # Monitor/Mutex since those are Kernel-included, and it can't be frozen).
    basic = Class.new(BasicObject).new
    # Must not raise; returns a shareable sentinel Symbol.
    result = RactorRailsShim._make_value_shareable(basic)
    assert Ractor.shareable?(result)
  end

  # --- Duck-typed lock detection (Issue #17) ---
  # The lock replacement should key on the `synchronize` message (the duck
  # type for a Mutex-like lock), not on concrete `is_a?(Monitor)||is_a?(Mutex)`
  # checks. A plain class that only defines `synchronize` is treated as a lock
  # and replaced with a shareable NoOpLock — this future-proofs against
  # third-party lock classes (e.g. Concurrent::LockableRuby Mutex variants,
  # async's Async::Semaphore) that are structurally locks but not subclasses.

  it "returns a shareable NoOpLock for a duck-typed lock (responds to :synchronize)" do
    fake_lock_class = Class.new do
      def synchronize; yield; end
    end
    result = RactorRailsShim._make_value_shareable(fake_lock_class.new)
    assert_kind_of NoOpLock, result
    assert Ractor.shareable?(result)
  end

  it "does NOT treat a plain object without :synchronize as a lock" do
    plain = Class.new { def foo; end }.new
    result = RactorRailsShim._make_value_shareable(plain)
    # Not a lock → routed to make_shareable (deep-frozen), not NoOpLock.
    refute_kind_of NoOpLock, result
  end
end