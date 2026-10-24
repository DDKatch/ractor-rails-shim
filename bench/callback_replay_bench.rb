# frozen_string_literal: true

# Micro-benchmark for the callback replay hot path (Callbacks::Registry +
# SymbolicTransport). Simulates a Rails-controller-shaped chain: a real class
# hierarchy ~25 ancestors deep, 5 :before entries (one gated by an if:
# condition), 2 :after entries, 1 :around entry, all on the leaf class.
#
# Measures full Registry#replay calls (the per-request cost for one callback
# chain kind). Run:
#   cd ../ractor-rails-shim-test-app && bundle exec ruby \
#     -I../ractor-rails-shim/lib ../ractor-rails-shim/bench/callback_replay_bench.rb

require_relative "../lib/ractor_rails_shim/callbacks"

# A realistic-ish controller hierarchy: 25 modules, leaf class holds the
# captured entries.
CHAIN_MODULES = Array.new(25) { Module.new }
CONTAINER = Class.new do
  CHAIN_MODULES.each { |m| include m }

  def action_name = :show
  def performed? = false

  %i[authenticate_user! set_post log_access verify_format run_guards
     touch_stamp notify_observer audit_trail around_txn].each do |m|
    define_method(m) { |&blk| blk&.call }
  end
  def gate = true
end

LEAF_ID = CONTAINER.object_id
ENTRIES = [
  { chain_kind: :process_action, phase: :before, filter: :authenticate_user!, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :before, filter: :set_post, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :before, filter: :log_access, only: nil, except: nil, if_cond: :gate, unless_cond: nil },
  { chain_kind: :process_action, phase: :before, filter: :verify_format, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :before, filter: :run_guards, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :around, filter: :around_txn, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :after, filter: :touch_stamp, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :after, filter: :notify_observer, only: nil, except: nil, if_cond: nil, unless_cond: nil },
  { chain_kind: :process_action, phase: :after, filter: :audit_trail, only: nil, except: nil, if_cond: nil, unless_cond: nil }
].freeze

TABLE = { LEAF_ID => ENTRIES }.freeze

# A fresh context per iteration is unrealistic; contexts are per-request but
# the chain COMPILE must not be (keyed by class, not context). One context,
# many replays measures the steady-state hot path.
CTX = CONTAINER.new

REGISTRY = RactorRailsShim::Callbacks::Registry.new([
  RactorRailsShim::Callbacks::SymbolicTransport.new(source: TABLE, kinds: [:process_action])
])

result = REGISTRY.replay(CTX, :process_action) { :body }
raise "replay broken: #{result.inspect}" unless result == :body

ITERS = 500_000
REGISTRY.replay(CTX, :process_action) { :body } # warm compile
best = 0.0
3.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ITERS.times { REGISTRY.replay(CTX, :process_action) { :body } }
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  best = [best, ITERS / dt / 1e6].max
end
puts format("callback_replay  %8.2f Mops/s (best of 3, %d-chain)", best, ENTRIES.size)
