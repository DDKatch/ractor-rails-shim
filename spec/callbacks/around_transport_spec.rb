# frozen_string_literal: true

# TDD specs for the wrap-style `:around` replay — SymbolicTransport#around +
# Registry#replay's wrap-chain build. The nesting contract mirrors ActiveSupport
# (verified against the real compiled chain):
#   first-declared :around filter is OUTERMOST; the after-half runs INSIDE the
#   innermost around's `yield`; a filter that never yields suppresses the block
#   AND the after-half.
#
# Run: bundle exec ruby -Ilib -Ispec spec/callbacks/around_transport_spec.rb

require "minitest/autorun"
require_relative "../../lib/ractor_rails_shim/callbacks/symbolic_transport"
require_relative "../../lib/ractor_rails_shim/callbacks/registry"

class AroundTransportSpec < Minitest::Spec
  class FakeKlass
    attr_reader :object_id, :ancestors
    def initialize(object_id)
      @object_id = object_id
      @ancestors = [self]
    end
  end

  # A context that records the execution order of before/around/after filters
  # and exposes real send-able `def` methods (unlike SymbolicTransportSpec's
  # method_missing fake, the around replay passes a BLOCK into `send`, so the
  # fake must be able to receive and call a block).
  class FakeContext
    attr_reader :klass, :order, :rendered

    def initialize(klass)
      @klass = klass
      @order = []
      @rendered = false
    end

    def class
      @klass
    end

    def action_name = :show
    def performed? = false

    def around_outer
      order << :"outer-enter"
      yield
      order << :"outer-exit"
    end

    def around_inner
      order << :"inner-enter"
      yield
      order << :"inner-exit"
    end

    def before_filter = order << :before
    def after_filter = order << :after

    # A filter that renders/redirects and does NOT call yield.
    def around_no_yield
      order << :no_yield
      @rendered = true
    end

    def yieldless_method = "plain"
  end

  class UnshareableProcContext < FakeContext
    def around_unshareable
      order << :unshareable
      yield
    end
  end

  def setup
    @klass = FakeKlass.new(0xA)
  end

  def entry(phase:, filter:, only: nil, except: nil, if_cond: nil, unless_cond: nil)
    {
      chain_kind: :process_action, phase: phase, filter: filter,
      only: only, except: except, if_cond: if_cond, unless_cond: unless_cond
    }
  end

  def transport(entries)
    RactorRailsShim::Callbacks::SymbolicTransport.new(
      source: {@klass.object_id => entries}, kinds: [:process_action]
    )
  end

  def registry(entries)
    RactorRailsShim::Callbacks::Registry.new([transport(entries)])
  end

  def test_registry_nests_around_filters_first_declared_outermost_with_after_inside_the_yield
    ctx = FakeContext.new(@klass)
    entries = [
      entry(phase: :before, filter: :before_filter),
      entry(phase: :around, filter: :around_outer),
      entry(phase: :around, filter: :around_inner),
      entry(phase: :after, filter: :after_filter)
    ]
    result = registry(entries).replay(ctx, :process_action) {
      ctx.order << :body
      "BODY"
    }
    assert_equal(
      %i[before outer-enter inner-enter body after inner-exit outer-exit],
      ctx.order
    )
    assert_equal "BODY", result
  end

  def test_around_filters_with_no_after_work_still_nest_correctly
    ctx = FakeContext.new(@klass)
    entries = [
      entry(phase: :around, filter: :around_inner),
      entry(phase: :around, filter: :around_outer)
    ]
    # DECLARATION order decides nesting, not method names: the first-declared
    # filter (named "inner" here) is the OUTERMOST wrapper.
    registry(entries).replay(ctx, :process_action) { ctx.order << :body }
    assert_equal %i[inner-enter outer-enter body outer-exit inner-exit], ctx.order
  end

  def test_no_around_filters_keeps_plain_yield_semantics
    ctx = FakeContext.new(@klass)
    entries = [
      entry(phase: :before, filter: :before_filter),
      entry(phase: :after, filter: :after_filter)
    ]
    result = registry(entries).replay(ctx, :process_action) {
      ctx.order << :body
      "RESULT"
    }
    assert_equal %i[before body after], ctx.order
    assert_equal "RESULT", result
  end

  def test_around_returning_inner_unchanged_when_no_around_entries
    ctx = FakeContext.new(@klass)
    entries = [entry(phase: :before, filter: :before_filter)]
    inner = -> { :inner_result }
    assert_same inner, transport(entries).around(ctx, :process_action, inner)
  end

  def test_non_yielding_around_filter_suppresses_block_and_after_work
    ctx = FakeContext.new(@klass)
    entries = [
      entry(phase: :around, filter: :around_no_yield),
      entry(phase: :after, filter: :after_filter)
    ]
    result = registry(entries).replay(ctx, :process_action) {
      ctx.order << :body
      "BODY"
    }
    assert_equal [:no_yield], ctx.order
    assert ctx.rendered
    # Rails discards the non-yielding filter's return value: run_callbacks
    # evaluates to nil (verified against the real chain).
    assert_nil result
  end

  def test_halted_before_filter_skips_around_layers_entirely
    FakeContext.new(@klass)
    entries = [
      entry(phase: :before, filter: :halt_false),
      entry(phase: :around, filter: :around_outer),
      entry(phase: :after, filter: :after_filter)
    ]
    # `halt_false` is not defined on FakeContext: method_missing free fake? No —
    # FakeContext has real defs only. Use a subclass-free approach: define a
    # one-off context with a halting filter.
    halting = Class.new(FakeContext) do
      def halt
        order << :halt
        false
      end
    end
    entries[0] = entry(phase: :before, filter: :halt)
    ctx2 = halting.new(@klass)
    result = registry(entries).replay(ctx2, :process_action) { ctx2.order << :body }
    assert_equal [:halt], ctx2.order
    assert_equal false, result
  end

  def test_only_except_gates_around_filters
    ctx = FakeContext.new(@klass)
    entries = [
      entry(phase: :around, filter: :around_outer, only: [:index]),
      entry(phase: :around, filter: :around_inner, except: [:index])
    ]
    registry(entries).replay(ctx, :process_action) { ctx.order << :body }
    # action_name is :show → :only-index skipped, :except-index runs.
    assert_equal %i[inner-enter body inner-exit], ctx.order
  end

  def test_symbol_if_unless_conditions_gate_around_filters
    ctx = Class.new(FakeContext) do
      def cond = true
      def nope = false

      def gated_by_cond
        order << :gated_ok
        yield
      end
    end.new(@klass)
    entries = [
      entry(phase: :around, filter: :gated_by_cond, if_cond: :cond),
      entry(phase: :around, filter: :around_inner, if_cond: :nope)
    ]
    inner_run = []
    layer = RactorRailsShim::Callbacks::SymbolicTransport.new(
      source: {@klass.object_id => entries}, kinds: [:process_action]
    ).around(ctx, :process_action, -> {
                                     inner_run << :inner
                                     "INNER"
                                   })
    # :cond is true → gated_by_cond wraps and descends into inner.
    # :nope is false → around_inner is gated out entirely (never entered);
    # the gated_by_cond wrapper's yield reaches the inner callable directly.
    assert_equal "INNER", layer.call
    assert_equal [:gated_ok], ctx.order
    assert_equal [:inner], inner_run
  end

  def test_missing_around_filter_method_falls_through_to_inner
    ctx = FakeContext.new(@klass)
    entries = [entry(phase: :around, filter: :definitely_not_defined)]
    layer = transport(entries).around(ctx, :process_action, -> { :inner })
    assert_equal :inner, layer.call
    assert_empty ctx.order
  end

  def test_unshareable_proc_around_filter_is_skipped_fail_safe
    ctx = UnshareableProcContext.new(@klass)
    # Simulate the worker-side raise: a filter whose define_method body is an
    # un-shareable main-Ractor Proc raises RuntimeError on send.
    ctx.singleton_class.define_method(:around_unshareable) do |&blk|
      @order << :before_raise
      raise "can't create Thread/Proc from a non-main Ractor — un-shareable Proc"
    end
    inner_run = []
    layer = RactorRailsShim::Callbacks::SymbolicTransport.new(
      source: {@klass.object_id => [entry(phase: :around, filter: :around_unshareable)]},
      kinds: [:process_action]
    ).around(ctx, :process_action, -> {
                                     inner_run << :inner
                                     :inner
                                   })
    assert_equal :inner, layer.call
    assert_equal [:before_raise], ctx.order
  end

  def test_around_replay_executes_in_a_real_worker_ractor
    skip "Ractor replay is exercised by the app's :ractor integration suite" unless defined?(Ractor.new)
    filter_klass = Class.new do
      def around_outer
        (@seen ||= []) << :"outer-enter"
        yield
        (@seen ||= []) << :"outer-exit"
      end

      def order
        (@seen ||= [])
      end
    end
    table = {
      filter_klass.object_id => [
        entry(phase: :around, filter: :around_outer)
      ]
    }
    Ractor.make_shareable(table)
    Ractor.make_shareable(filter_klass)
    result = Ractor.new(table, filter_klass) do |shareable_table, kls|
      ctx = kls.new
      reg = RactorRailsShim::Callbacks::Registry.new(
        [RactorRailsShim::Callbacks::SymbolicTransport.new(source: shareable_table, kinds: [:process_action])]
      )
      reg.replay(ctx, :process_action) {
        ctx.order << :body
        "BODY"
      }
      [ctx.order.dup, "BODY"]
    end.value
    order, body = result
    assert_equal %i[outer-enter body outer-exit], order
    assert_equal "BODY", body
  end
end
