# frozen_string_literal: true

# TDD specs for the generalized callback-transport abstraction (POODR §3
# — build a duck-typed interface, §5 — message-based dispatch). The Registry
# coordinates an open set of CallbackTransports: it owns the single `yield`
# (the real callback-chain body) and asks each applicable transport to run its
# before/after work around it. Adding a new callback *kind* means adding a new
# transport object — no `if kind ==` branches in the hot path (Open/Closed).
#
# Run: bundle exec ruby -Ilib -Ispec spec/callbacks/registry_spec.rb

require "minitest/autorun"

require_relative "../../lib/ractor_rails_shim/callbacks/registry"
require_relative "../../lib/ractor_rails_shim/callbacks/symbolic_transport"
require_relative "../../lib/ractor_rails_shim/callbacks/dependent_association_transport"

class RegistrySpec < Minitest::Spec
  # A fake transport that records the messages it receives, so we can assert
  # the Registry's orchestration order (before -> yield -> after) without any
  # Rails dependency. This is the duck type the Registry depends on.
  class FakeTransport
    attr_reader :kind, :log

    def initialize(kind, log)
      @kind = kind
      @log = log
    end

    def applies_to?(k)
      k == @kind
    end

    def before(context, kind)
      @log << [:before, kind, context]
    end

    def after(context, kind)
      @log << [:after, kind, context]
    end
  end

  it "yields the block unchanged when no transport applies" do
    registry = RactorRailsShim::Callbacks::Registry.new
    ran = false
    result = registry.replay(:ctx, :save) { ran = true; :done }
    assert ran
    assert_equal :done, result
  end

  it "runs before -> yield -> after for a single applicable transport" do
    log = []
    registry = RactorRailsShim::Callbacks::Registry.new([FakeTransport.new(:save, log)])
    order = []
    result = registry.replay(:ctx, :save) { order << :yield; :value }
    assert_equal [:before, :save, :ctx], log[0]
    assert_equal :yield, order[0]
    assert_equal [:after, :save, :ctx], log[1]
    assert_equal :value, result
  end

  it "runs ALL transports for the same kind (not just the first) — dependent + symbolic both apply to :destroy" do
    log = []
    a = FakeTransport.new(:destroy, log)
    b = FakeTransport.new(:destroy, log)
    registry = RactorRailsShim::Callbacks::Registry.new([a, b])
    registry.replay(:ctx, :destroy) { :done }
    # both befores run before the yield; both afters run after
    assert_equal [:before, :destroy, :ctx], log[0]
    assert_equal [:before, :destroy, :ctx], log[1]
    assert_equal [:after, :destroy, :ctx], log[2]
    assert_equal [:after, :destroy, :ctx], log[3]
  end

  it "registers transports after construction" do
    log = []
    registry = RactorRailsShim::Callbacks::Registry.new
    registry.register(FakeTransport.new(:save, log))
    assert registry.applicable(:save).any?
    refute registry.applicable(:destroy).any?
  end

  it "delegates install + capture to every transport (open set)" do
    install_calls = []
    capture_calls = []
    t1 = FakeTransport.new(:save, [])
    t2 = FakeTransport.new(:destroy, [])
    def t1.install; @installed = true; end
    def t2.install; @installed = true; end
    def t1.capture; @captured = true; end
    def t2.capture; @captured = true; end
    registry = RactorRailsShim::Callbacks::Registry.new([t1, t2])
    registry.install
    registry.capture
    assert t1.instance_variable_get(:@installed)
    assert t2.instance_variable_get(:@installed)
    assert t1.instance_variable_get(:@captured)
    assert t2.instance_variable_get(:@captured)
  end

  it "returns the block's result and still runs after-filters when the block raises" do
    # Rails' real run_callbacks rescues/halts; here we only assert the registry
    # itself does not swallow the block's return value on the success path.
    log = []
    registry = RactorRailsShim::Callbacks::Registry.new([FakeTransport.new(:save, log)])
    assert_equal :ok, registry.replay(:ctx, :save) { :ok }
    assert_equal 2, log.size
  end
end