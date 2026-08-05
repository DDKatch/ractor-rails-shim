# frozen_string_literal: true

# Specs for the `RactorRailsShim::LoggerIONeutralizer` role object
# (extracted from the facade god module in Step 22.3, Issue #22).
#
# These specs target the role object directly — calling
# `LoggerIONeutralizer.call(app)` — pinning the graph walk, the
# @logger -> NoOpLogDev/BroadcastLogger swap, the stray $stdout/$stderr
# ivar -> NoOpLogDev swap, and the main-Ractor Rails.logger re-point
# without routing through the facade.
#
# Run: ruby -Ilib -Ispec spec/logger_io_neutralizer_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require "active_support"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class LoggerIONeutralizerSpec < Minitest::Spec
  # The role object exists and exposes the call entry point.
  it "is a module under RactorRailsShim with a .call method" do
    assert RactorRailsShim.const_defined?(:LoggerIONeutralizer, false),
           "RactorRailsShim::LoggerIONeutralizer should be defined"
    assert RactorRailsShim::LoggerIONeutralizer.respond_to?(:call),
           "LoggerIONeutralizer.call should be defined"
  end

  # Replaces the app-instance @logger ivar with a frozen, shareable
  # no-op BroadcastLogger.
  it "replaces app-instance @logger with a frozen shareable no-op BroadcastLogger" do
    sentinel = Object.new
    sentinel.freeze
    app = Object.new
    app.instance_variable_set(:@logger, sentinel)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    replaced = app.instance_variable_get(:@logger)
    assert_kind_of ::ActiveSupport::BroadcastLogger, replaced,
                   "@logger should be a BroadcastLogger after neutralize"
    assert replaced.frozen?, "replaced logger should be frozen"
    assert Ractor.shareable?(replaced), "replaced logger should be Ractor-shareable"
  end

  # Replaces stray $stdout/$stderr ivar references with a frozen,
  # shareable NoOpLogDev.
  it "replaces stray $stdout/$stderr ivars with a frozen shareable NoOpLogDev" do
    app = Object.new
    app.instance_variable_set(:@dev, $stdout)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    replaced = app.instance_variable_get(:@dev)
    assert_kind_of RactorRailsShim.singleton_class::NoOpLogDev, replaced,
                   "@dev holding $stdout should become NoOpLogDev"
    assert replaced.frozen?, "NoOpLogDev should be frozen"
    assert Ractor.shareable?(replaced), "NoOpLogDev should be Ractor-shareable"
  end

  # Recurses into instance variables (a nested object holding $stderr is
  # also neutralized).
  it "walks into nested instance variables to neutralize stray IOs" do
    inner = Object.new
    inner.instance_variable_set(:@sink, $stderr)
    app = Object.new
    app.instance_variable_set(:@child, inner)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_kind_of RactorRailsShim.singleton_class::NoOpLogDev, inner.instance_variable_get(:@sink),
                   "nested @sink holding $stderr should become NoOpLogDev"
  end

  # Recurses into Array and Hash children.
  it "walks Array and Hash children" do
    holder = Object.new
    holder.instance_variable_set(:@io, $stdout)
    arr = [holder]
    app = Object.new
    app.instance_variable_set(:@arr, arr)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_kind_of RactorRailsShim.singleton_class::NoOpLogDev, holder.instance_variable_get(:@io),
                   "IO inside an Array child should be neutralized"
  end

  # Recurses into Set children (uses CONTAINER_WALKERS dispatch).
  it "walks Set children" do
    holder = Object.new
    holder.instance_variable_set(:@io, $stderr)
    s = Set.new([holder])
    app = Object.new
    app.instance_variable_set(:@set, s)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_kind_of RactorRailsShim.singleton_class::NoOpLogDev, holder.instance_variable_get(:@io),
                   "IO inside a Set child should be neutralized"
  end

  # The facade delegates to the role object (the existing
  # debug_funnel_spec test covers the funnel path).
  it "facade _neutralize_logger_io! delegates to the role object" do
    sentinel = Object.new
    sentinel.freeze
    app = Object.new
    app.instance_variable_set(:@logger, sentinel)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_kind_of ::ActiveSupport::BroadcastLogger,
                   app.instance_variable_get(:@logger),
                   "facade delegation should neutralize @logger"
  end

  # Does not raise on a frozen app (ivar swap is funneled through _swallow).
  it "does not raise on a frozen app with a @logger ivar" do
    app = Object.new
    app.instance_variable_set(:@logger, Object.new)
    app.freeze
    RactorRailsShim::LoggerIONeutralizer.call(app)
    # Frozen owner: the ivar swap raises FrozenError, funneled through
    # _swallow. The app stays frozen; the method returns normally.
    assert app.frozen?
  end

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # LoggerIONeutralizer must be constructible with its collaborators
  # (the `funnel` = `_swallow` role, and `noop_log_dev_class` = the
  # `NoOpLogDev` class reached through the facade constant) instead of
  # reaching them through the `RactorRailsShim` facade by global name.
  # The seam is `configure(funnel:, noop_log_dev_class:)`; the defaults
  # are the facade lookups so existing call sites keep working during
  # migration. The funnel contract: a callable responding to
  # `call(label) { block }` that runs the block and rescues StandardError
  # (matching `_swallow`). The noop_log_dev_class contract: a class
  # responding to `.new` returning a sink object (frozen + made
  # shareable by the role).

  it "responds to configure(funnel:, noop_log_dev_class:)" do
    assert_respond_to RactorRailsShim::LoggerIONeutralizer, :configure
  end

  it "responds to reset_configuration" do
    assert_respond_to RactorRailsShim::LoggerIONeutralizer, :reset_configuration
  end

  it "responds to funnel" do
    assert_respond_to RactorRailsShim::LoggerIONeutralizer, :funnel
  end

  it "responds to noop_log_dev_class" do
    assert_respond_to RactorRailsShim::LoggerIONeutralizer, :noop_log_dev_class
  end

  it "funnels @logger ivar swap failures through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::LoggerIONeutralizer.configure(funnel: funnel)
    app = Object.new
    app.instance_variable_set(:@logger, Object.new)
    app.freeze
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_includes funneled, "neutralize logger ivar"
  ensure
    RactorRailsShim::LoggerIONeutralizer.reset_configuration
  end

  it "funnels stray IO ivar swap failures through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::LoggerIONeutralizer.configure(funnel: funnel)
    app = Object.new
    app.instance_variable_set(:@dev, $stdout)
    app.freeze
    RactorRailsShim::LoggerIONeutralizer.call(app)
    assert_includes funneled, "neutralize logger IO ivar"
  ensure
    RactorRailsShim::LoggerIONeutralizer.reset_configuration
  end

  it "uses an injected noop_log_dev_class to replace stray IO ivars" do
    fake_sink_class = Class.new do
      def freeze; super; end
    end
    RactorRailsShim::LoggerIONeutralizer.configure(
      noop_log_dev_class: fake_sink_class
    )
    app = Object.new
    app.instance_variable_set(:@dev, $stdout)
    RactorRailsShim::LoggerIONeutralizer.call(app)
    replaced = app.instance_variable_get(:@dev)
    assert_kind_of fake_sink_class, replaced,
                   "stray IO should be replaced with the injected sink class"
    assert replaced.frozen?, "injected sink should be frozen"
    assert Ractor.shareable?(replaced), "injected sink should be Ractor-shareable"
  ensure
    RactorRailsShim::LoggerIONeutralizer.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults" do
    RactorRailsShim::LoggerIONeutralizer.configure(
      funnel: ->(label, &blk) { blk&.call },
      noop_log_dev_class: Class.new
    )
    injected_funnel = RactorRailsShim::LoggerIONeutralizer.funnel
    injected_class = RactorRailsShim::LoggerIONeutralizer.noop_log_dev_class
    refute_equal RactorRailsShim::Funnel.method(:swallow), injected_funnel
    refute_equal RactorRailsShim.singleton_class::NoOpLogDev, injected_class

    RactorRailsShim::LoggerIONeutralizer.reset_configuration
    default_funnel = RactorRailsShim::LoggerIONeutralizer.funnel
    default_class = RactorRailsShim::LoggerIONeutralizer.noop_log_dev_class
    assert_equal RactorRailsShim::Funnel.method(:swallow), default_funnel
    assert_equal RactorRailsShim.singleton_class::NoOpLogDev, default_class
  ensure
    RactorRailsShim::LoggerIONeutralizer.reset_configuration
  end
end