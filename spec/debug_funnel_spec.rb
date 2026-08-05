# frozen_string_literal: true

# Specs for the `_swallow` debug funnel and `debug?` flag.
#
# The shim's freeze/shareability paths rescue many exceptions silently
# (individual ivars may hold intrinsically unshareable values like Procs).
# Pre-cleanup these were bare `rescue; nil`, so a worker Ractor that later
# crashed on an unshareable value had no traceable cause. The `_swallow`
# funnel centralizes the swallow: silent by default, but emits a labeled
# $stderr line when `RactorRailsShim.debug = true`.
#
# Run: ruby -Ilib -Ispec spec/debug_funnel_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require "active_support/logger"
require "active_support/broadcast_logger"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class DebugFunnelSpec < Minitest::Spec
  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it "debug? defaults to false" do
    RactorRailsShim.instance_variable_set(:@debug, nil) # reset
    refute RactorRailsShim.debug?
  end

  it "debug = true is honoured" do
    RactorRailsShim.debug = true
    assert RactorRailsShim.debug?
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow returns the block's value on success" do
    assert_equal 42, RactorRailsShim._swallow("test") { 42 }
  end

  it "_swallow returns nil on exception and is silent by default" do
    RactorRailsShim.debug = false
    out = capture_stderr do
      assert_nil RactorRailsShim._swallow("test") { raise RuntimeError, "boom" }
    end
    assert_empty out, "no stderr output when debug? is false"
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow emits a labeled $stderr line when debug? is true" do
    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim._swallow("freeze AR ivar Post@column_defaults") do
        raise RuntimeError, "can't freeze a Proc"
      end
    end
    assert_includes out, "[ractor_rails_shim]"
    assert_includes out, "freeze AR ivar Post@column_defaults"
    assert_includes out, "RuntimeError"
    assert_includes out, "can't freeze a Proc"
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow truncates long messages so stderr stays readable" do
    RactorRailsShim.debug = true
    long_msg = "x" * 500
    out = capture_stderr do
      RactorRailsShim._swallow("lbl") { raise RuntimeError, long_msg }
    end
    # The line should not contain the full 500-char message.
    refute_includes out, long_msg
    assert_includes out, "x" * 120 # truncated to ~120 chars
  ensure
    RactorRailsShim.debug = false
  end

  # Regression guard: the freeze-path methods (_freeze_shareable_class_ivars!,
  # _freeze_declared_callbacks!, _collect_controller_classes) used bare
  # `rescue; nil` blocks that bypassed _swallow, so `debug=true` never
  # surfaced their failures. Each should emit a labeled $stderr line when
  # debug? is true and the underlying call raises.
  def _with_silent_const_path(label, &block)
    # Stub the constant path / internal call so the freeze-path method raises
    # predictably. Yield the block inside capture_stderr + debug=true.
    RactorRailsShim.debug = true
    out = capture_stderr do
      block.call
    end
    assert_includes out, "[ractor_rails_shim]", "#{label}: no [ractor_rails_shim] tag"
    assert_includes out, label, "#{label}: label not in stderr"
  ensure
    RactorRailsShim.debug = false
  end

  it "_freeze_shareable_class_ivars! funnels failures through _swallow (labeled)" do
    # Force a failure: a frozen module can't have its ivar reassigned by
    # `instance_variable_set`, which raises FrozenError inside the method's
    # _swallow block. Use a frozen module with a present ivar so the
    # `next unless ... instance_variable_defined?` guard passes and execution
    # reaches the set call.
    target = Module.new
    Object.const_set(:ShimFreezeIvarProbe, target)
    target.instance_variable_set(:@editors, {})
    target.freeze
    RactorRailsShim::SHAREABLE_CLASS_IVARS << ["ShimFreezeIvarProbe", :@editors]
    label = "freeze global ivar"
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_freeze_shareable_class_ivars!)
    end
  ensure
    RactorRailsShim::SHAREABLE_CLASS_IVARS.delete(["ShimFreezeIvarProbe", :@editors])
    Object.send(:remove_const, :ShimFreezeIvarProbe) if defined?(ShimFreezeIvarProbe)
  end

  it "_freeze_declared_callbacks! funnels failures through _swallow (labeled)" do
    # Force const_set to raise by stubbing RactorRailsShim.const_set. The
    # method's begin block calls const_set; raising there exercises the
    # rescue path, which should go through _swallow with a recognizable label.
    label = "freeze declared callbacks"
    RactorRailsShim.singleton_class.send(:alias_method, :_orig_const_set, :const_set)
    RactorRailsShim.define_singleton_method(:const_set) do |*a|
      raise RuntimeError, "forced-const-set-failure"
    end
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_freeze_declared_callbacks!)
    end
  ensure
    RactorRailsShim.singleton_class.send(:alias_method, :const_set, :_orig_const_set)
    RactorRailsShim.singleton_class.send(:remove_method, :_orig_const_set)
  end

  it "_collect_controller_classes funnels failures through _swallow (labeled)" do
    # Pass an app whose routes() raises so the begin block in
    # _collect_controller_classes fires its rescue path.
    label = "collect controller classes"
    app = Object.new
    def app.routes; raise RuntimeError, "forced-routes-failure"; end
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_collect_controller_classes, app)
    end
  end

  # --- Step 2b: freeze-path make_shareable / graph-mutation sites ---
  #
  # Each of the following forces a failure inside a freeze-path block that
  # previously used a bare `rescue nil`, bypassing _swallow. The fix is to
  # route through _swallow so debug=true surfaces the failure with a label.

  # Helper: stub Ractor.make_shareable to raise for the duration of the block.
  def _with_make_shareable_raising
    RactorRailsShim.singleton_class.send(:alias_method, :_orig_make_shareable, :Ractor.make_shareable)
    RactorRailsShim.singleton_class.define_singleton_method(:Ractor) do
      Module.new do
        def self.make_shareable(_)
          raise RuntimeError, "forced-make-shareable-failure"
        end
      end
    end
    yield
  ensure
    # Restore by removing the singleton override; Ractor is global so we
    # can't actually stub it cleanly — instead use a different mechanism
    # below. This helper is unused in practice; kept for documentation.
  end

  # Stub the global Ractor.make_shareable by reopening. Simpler: alias the
  # shim's own singleton method reference and have the shim's _swallow sites
  # call a private helper. Since the shim calls ::Ractor.make_shareable
  # directly, we stub ::Ractor.make_shareable itself.
  def _with_stubbed_make_shareable_raising
    ::Ractor.singleton_class.send(:alias_method, :_orig_make_shareable, :make_shareable)
    ::Ractor.define_singleton_method(:make_shareable) do |_|
      raise RuntimeError, "forced-make-shareable-failure"
    end
    yield
  ensure
    ::Ractor.singleton_class.send(:alias_method, :make_shareable, :_orig_make_shareable)
    ::Ractor.singleton_class.send(:remove_method, :_orig_make_shareable)
  end

  it "_replace_locks_and_concurrent_maps! funnels make_shareable/set failures through _swallow (labeled)" do
    # Force a failure on the lock-replacement path by passing a frozen object
    # whose ivar is a Mutex: `instance_variable_set(:@lock, NoOpLock.new)`
    # raises FrozenError, which should funnel through _swallow.
    label = "replace lock ivar"
    parent = Class.new do
      attr_reader :lock
      def initialize; @lock = Mutex.new; end
    end.new
    parent.freeze
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_replace_locks_and_concurrent_maps!, parent)
    end
  end

  it "_replace_one_proc funnels ivar-set failures through _swallow (labeled)" do
    # A frozen parent with a Proc ivar: _replace_one_proc computes a
    # NoOpProc replacement and tries `parent.instance_variable_set(ivar, rep)`,
    # which raises FrozenError. The label should appear in stderr.
    skip "requires RactorRailsShim::NoOpProc" unless RactorRailsShim.singleton_class.const_defined?(:NoOpProc)
    label = "replace proc ivar"
    parent = Class.new do
      attr_reader :p
      def initialize; @p = ->(*) { :x }; end
    end.new
    parent.freeze
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_replace_unshareable_procs!, parent)
    end
  end

  it "_neutralize_logger_io! funnels logger/IO replacement failures through _swallow (labeled)" do
    # A frozen app with a @logger ivar: swapping it raises FrozenError, which
    # should funnel through _swallow. The method also re-points Rails.logger
    # at the end (line ~191); that's incidental to this test and may raise if
    # the Rails module isn't fully installed — guard it so the test stays
    # hermetic to what we're actually asserting (the ivar-swap funnel).
    label = "neutralize logger ivar"
    app = Class.new do
      attr_reader :logger
      def initialize; @logger = Object.new; end
    end.new
    app.freeze
    _with_silent_const_path(label) do
      RactorRailsShim.send(:_neutralize_logger_io!, app) rescue nil
    end
  end

  it "DeviseMappingSnapshot funnels controllers.each failure through _swallow (labeled)" do
    # Construct a fake mapping whose controllers raises, so the
    # `mapping.controllers.each { ... } rescue nil` inside
    # DeviseMappingSnapshot#initialize fails and funnels through _swallow.
    # We don't require the real devise gem here; stub a minimal ::Devise
    # constant with FailureApp + NO_INPUT so the snapshot class can resolve
    # its constants.
    fake_devise = Module.new
    fake_devise.const_set(:FailureApp, Class.new)
    fake_devise.const_set(:NO_INPUT, [].freeze)
    Object.const_set(:Devise, fake_devise) unless defined?(::Devise)
    had_devise = defined?(::Devise)

    mapping = Object.new
    def mapping.name; :users; end
    def mapping.to; Class.new; end
    def mapping.instance_variable_get(iv)
      case iv.to_s
      when /router_name|singular|scoped_path|path|path_prefix|format|sign_out_via|failure_app/ then nil
      else super
      end
    end
    def mapping.modules; []; end
    def mapping.strategies; []; end
    def mapping.routes; []; end
    def mapping.used_helpers; []; end
    def mapping.controllers; raise RuntimeError, "forced-controllers-failure"; end

    label = "devise mapping controllers"
    snap_cls = RactorRailsShim.singleton_class.const_get(:DeviseMappingSnapshot)
    _with_silent_const_path(label) do
      snap_cls.new(mapping)
    end
  ensure
    Object.send(:remove_const, :Devise) unless had_devise
  end
end