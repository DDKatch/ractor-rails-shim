# frozen_string_literal: true

# Micro-benchmark for the shim's class-attribute READ hot paths.
#
# Measures the structural cost of each lookup shape, independent of any app:
#
#   1. ivar          — a plain Ruby attr_reader (the floor / what unpatched
#                      Rails pays)
#   2. exact_ies     — IESAccessor-generated reader, value present in IES
#                      (the worker hot path after Commit D prefill, or any
#                      per-ractor override)
#   3. exact_fallback— same reader, IES empty, value in SHAREABLE_FALLBACK
#                      (the worker hot path today)
#   4. exact_miss    — IES + fallback empty, main-ractor tier 3
#   5. resolved_hot  — class_attribute reader via lookup_resolved after the
#                      first read populated the per-receiver cache
#   6. by_attr_cold  — lookup_by_attr ancestor walk, nothing cached
#                      (10-module ancestor chain)
#
# Run under a bundle where ActiveSupport is available (IES backend):
#   cd ../ractor-rails-shim-test-app && bundle exec ruby \
#     -I../ractor-rails-shim/lib ../ractor-rails-shim/bench/accessor_read_bench.rb

require "benchmark/ips" unless ARGV.include?("--manual")
require "active_support/isolated_execution_state"
require "ractor_rails_shim"

RactorRailsShim.storage_strategy = RactorRailsShim::StorageStrategy::Ractor

KEY = :"rrs_bench_exact_key"
RESOLVED = :"rrs_bench_resolved_key"

Registry = RactorRailsShim::Registry
Registry.reassign_shareable_fallback(
  Ractor.make_shareable({ KEY => "fallback_value" })
)

Ies = RactorRailsShim.storage

Target = Class.new do
  attr_reader :plain
  def initialize; @plain = "ivar_value"; end
end
RactorRailsShim::IESAccessor.define_reader(Target, :shim_reader, KEY)

# 10-module ancestor chain so the by_attr shape pays a realistic walk.
ANCESTORS = Array.new(10) { |i| Module.new.tap { |m| m.instance_variable_set(:@i, i) } }
WalkTarget = Class.new do
  ANCESTORS.each { |m| include m }
end

# Seed the fallback with WalkTarget's class_attribute storage key so the
# by_attr walk resolves at the class level (its own value, not inherited).
CA_KEY = RactorRailsShim::StorageStrategy.ca_key(WalkTarget, :bench_attr)
Registry.reassign_shareable_fallback(
  Ractor.make_shareable({
    KEY => "fallback_value",
    CA_KEY => "fallback_value"
  })
)

def resolved_reader(obj)
  RactorRailsShim::StorageStrategy::Ractor.lookup_resolved(obj, :bench_attr, nil, RESOLVED)
end

# Populate the resolved cache + IES hot value.
RactorRailsShim.storage[KEY] = "ies_value"
resolved_reader(WalkTarget.new)
RactorRailsShim.storage.delete(KEY) # restore: exact_fallback should hit tier 2

WARM = Target.new
WALK = WalkTarget.new

# Sanity assertions — each shape must return its expected value.
raise "ivar"        unless WARM.plain == "ivar_value"
raise "exact_ies"   unless (Ies[KEY] = "ies_value"; WARM.shim_reader == "ies_value")
raise "exact_fallback" unless (Ies.delete(KEY); WARM.shim_reader == "fallback_value")
raise "resolved_hot" unless resolved_reader(WALK) == "fallback_value"

if defined?(Benchmark::IPS)
  Benchmark.ips do |x|
    x.report("ivar")           { WARM.plain }
    x.report("exact_ies")      { Ies[KEY] = "ies_value"; WARM.shim_reader }
    x.report("exact_fallback") { Ies.delete(KEY); WARM.shim_reader }
    x.report("resolved_hot")   { resolved_reader(WALK) }
    x.report("by_attr_walk")   do
      RactorRailsShim::StorageStrategy::Ractor.lookup_by_attr(WALK, :bench_attr, nil)
    end
    x.compare!
  end
else
  ITERS = 2_000_000
  REPS = 3
  puts format("%-16s %10s", "shape", "Mops/s (best of #{REPS})")
  {
    "ivar"           => -> { WARM.plain },
    "exact_ies"      => -> { Ies[KEY] = "ies_value"; WARM.shim_reader },
    "exact_fallback" => -> { Ies.delete(KEY); WARM.shim_reader },
    "resolved_hot"   => -> { resolved_reader(WALK) },
    "by_attr_walk"   => -> { RactorRailsShim::StorageStrategy::Ractor.lookup_by_attr(WALK, :bench_attr, nil) }
  }.each do |name, fn|
    fn.call # warm
    best = 0.0
    REPS.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ITERS.times { fn.call }
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      best = [best, ITERS / dt / 1e6].max
    end
    puts format("%-16s %10.2f", name, best)
  end
end
