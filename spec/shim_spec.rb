# frozen_string_literal: true

# Minimal proof-of-concept test for ractor-rails-shim.
# Uses a fake Rails-style module (no Rails dependency) to verify:
#   1. Class ivars raise Ractor::IsolationError from a worker Ractor (before shim)
#   2. The shim's IES-rerouted accessors work from a worker Ractor (after shim)
#   3. Each Ractor gets its own value (per-Ractor isolation)
#   4. Main Ractor's value is unaffected
#
# Run: ruby spec/shim_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Fake Rails-style module with class ivars — the exact pattern the shim targets.
module FakeRails
  class << self
    attr_accessor :cache, :logger

    def application
      @application ||= "default-app-from-#{Ractor.current}"
    end

    def application=(val)
      @application = val
    end
  end

  # Set some values in main Ractor (simulates boot)
  self.cache = "main-cache"
  self.logger = "main-logger"
  self.application = "main-app"
end

# Minimal mattr_accessor stub on Module, so super in the prepended patch finds it.
unless Module.method_defined?(:mattr_accessor, true)
  Module.module_eval do
    def mattr_accessor(name, default: nil, **)
      instance_variable_set(:"@#{name}", default)
      define_singleton_method(name) { instance_variable_get(:"@#{name}") }
      define_singleton_method(:"#{name}=") { |v| instance_variable_set(:"@#{name}", v) }
    end
  end
end

# Apply the shim's mattr_accessor patch (prepends a module that calls super).
RactorRailsShim.send(:install_mattr_accessor)

module FakeActiveRecord
  mattr_accessor :connection_handler, default: "main-connection-handler"
end

# A SECOND fake module used only for the "before shim" test, so test order
# doesn't matter (FakeRails.cache gets patched in test 2).
module UnpatchedFakeRails
  class << self
    attr_accessor :cache
  end
  # Mutable Array (not a frozen string literal) so the value is unshareable.
  # frozen_string_literal: true would make "main" frozen/shareable, which
  # would NOT raise IsolationError — we need an unshareable value to prove
  # the blocker exists.
  self.cache = []
end

class ShimSpec < Minitest::Spec
  def self.test_order
    :alpha # run in definition order so we can compare before/after
  end

  # --- BEFORE shim: prove the blocker exists ---
  # Use a NAMED constant module (shared across ractors) — anonymous modules
  # get deep-copied when sent to a ractor, so the ivar read wouldn't raise.
  it "class ivar read from a worker Ractor raises IsolationError (no shim)" do
    port = Ractor::Port.new
    r = Ractor.new(port) do |p|
      begin
        UnpatchedFakeRails.cache # reads @cache on the shared constant
        p.send(:no_error)
      rescue Ractor::IsolationError => e
        p.send(:isolation_error)
      rescue => e
        p.send(:"other_#{e.class}: #{e.message[0,50]}")
      end
    end
    result = port.receive
    assert_equal :isolation_error, result, "got #{result.inspect}"
  end

  # --- AFTER shim: manually reroute FakeRails' accessors (what install_rails_module does) ---
  it "IsolatedExecutionState-rerouted accessor works from a worker Ractor" do
    # Patch FakeRails via module_eval string (NOT define_method — blocks
    # capture the main ractor's binding and can't be called from workers).
    FakeRails.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
      def cache
        v = ActiveSupport::IsolatedExecutionState[:ractor_shim_fake_cache]
        return v unless v.nil?
        if Ractor.main? && instance_variable_defined?(:@cache)
          @cache
        end
      end

      def cache=(val)
        ActiveSupport::IsolatedExecutionState[:ractor_shim_fake_cache] = val
        @cache = val if Ractor.main?
        val
      end
    RUBY

    port = Ractor::Port.new
    r = Ractor.new(port) do |p|
      begin
        v = FakeRails.cache # now reads from IES, no IsolationError
        FakeRails.cache = "worker-cache"
        v2 = FakeRails.cache
        p.send({ read: v, after_set: v2 })
      rescue => e
        p.send("err: #{e.class}: #{e.message[0,80]}")
      end
    end

    result = port.receive
    assert_kind_of Hash, result, "expected hash, got: #{result.inspect}"
    # Worker reads nil (own IES slot empty, no fallback to class ivar from worker)
    assert_nil result[:read], "worker should see nil initially (own IES slot, no class-ivar fallback)"
    assert_equal "worker-cache", result[:after_set]
  end

  it "per-Ractor isolation: each Ractor gets its own value via IES" do
    # Clean slate
    ActiveSupport::IsolatedExecutionState.delete(:ractor_shim_test)
    Thread.current[:active_support_execution_state] = nil

    port = Ractor::Port.new
    r = Ractor.new(port) do |p|
      v = ActiveSupport::IsolatedExecutionState[:ractor_shim_test]
      ActiveSupport::IsolatedExecutionState[:ractor_shim_test] = "from-worker"
      v2 = ActiveSupport::IsolatedExecutionState[:ractor_shim_test]
      p.send({ initial: v, after_set: v2 })
    end

    result = port.receive
    assert_kind_of Hash, result
    assert_nil result[:initial], "worker should see nil initially (own IES slot)"
    assert_equal "from-worker", result[:after_set]
  end

  it "mattr_accessor-rerouted accessor works from a worker Ractor" do
    # FakeActiveRecord.connection_handler was defined with mattr_accessor,
    # which the shim rewrote. Worker should be able to read/set it.
    port = Ractor::Port.new
    r = Ractor.new(port) do |p|
      begin
        v = FakeActiveRecord.connection_handler
        FakeActiveRecord.connection_handler = "worker-handler"
        v2 = FakeActiveRecord.connection_handler
        p.send({ read: v, after_set: v2 })
      rescue Ractor::IsolationError => e
        p.send("isolation_err: #{e.message[0,80]}")
      rescue => e
        p.send("err: #{e.class}: #{e.message[0,80]}")
      end
    end

    result = port.receive
    assert_kind_of Hash, result, "mattr_accessor should work from ractor, got: #{result.inspect}"
    # Worker gets the default value (lazy-init from default:)
    assert_equal "main-connection-handler", result[:read], "worker should get default"
    assert_equal "worker-handler", result[:after_set]
  end

  it "main Ractor's value is not affected by worker Ractor writes" do
    # Set in main
    ActiveSupport::IsolatedExecutionState[:ractor_shim_main_test] = "main-value"

    port = Ractor::Port.new
    r = Ractor.new(port) do |p|
      ActiveSupport::IsolatedExecutionState[:ractor_shim_main_test] = "worker-value"
      p.send(:done)
    end
    port.receive

    assert_equal "main-value", ActiveSupport::IsolatedExecutionState[:ractor_shim_main_test]
  end
end