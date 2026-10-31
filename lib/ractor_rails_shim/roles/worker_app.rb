# frozen_string_literal: true

# WorkerApp: the shareable Rack wrapper that performs per-worker one-time
# initialization, extracted from patches/core.rb into its own file (Issue #13,
# Step 13.4; POODR §1 SRP — "small objects in their own files").
#
# On the first request served by each worker Ractor it:
#   1. rebinds the captured application constants into that worker's
#      namespace (so bare `Post` etc. resolve), then
#   2. ensures the worker's ActiveRecord connection handler is initialized.
#
# The wrapper holds only shareable state (@app, @bindings), so the instance
# is `Ractor.make_shareable`'d by `WorkerAppFactory.build` before being
# handed to worker Ractors. `Ractor.current` provides per-worker storage
# for the one-time guard, avoiding any top-level constant reference.

module RactorRailsShim
  class WorkerApp
    def initialize(app, bindings)
      @app = app
      @bindings = bindings
    end

    def call(env)
      setup_once!
      @app.call(env)
    end

    private

    def setup_once!
      # All threads inside a worker Ractor share Ractor.current, so a single
      # per-Ractor mutex serializes the one-time init across the worker's
      # threads. `Ractor.current[:key] ||= Thread::Mutex.new` is NOT atomic
      # (read-then-write; under a widened window N racing threads produce N
      # distinct mutexes — verified by spec). The race is benign ONLY because
      # the gated work is idempotent:
      #   - `rebind_constants` guards each `const_set` with
      #     `unless const_defined?`, so a redundant call is a no-op.
      #   - `init_worker_ar_connections!` returns early if the connection
      #     handler is already established.
      # A per-Ractor mutex can't be pre-created (it isn't Ractor-shareable,
      # so it can't travel from main to workers), and a global cross-Ractor
      # lock is impossible (Mutex isn't shareable either). The idempotency
      # contract is therefore load-bearing: if either step ever loses
      # idempotency, redundant calls under the race would become incorrect.
      # The spec `rebind_constants is idempotent under repeated calls` pins
      # this.
      m = Ractor.current[:rrs_worker_mutex] ||= Thread::Mutex.new
      m.synchronize do
        return if Ractor.current[:rrs_worker_ready]
        rebind_constants
        RactorRailsShim.init_worker_ar_connections! if defined?(RactorRailsShim)
        prefill_ies_from_fallback!
        run_worker_boot_blocks!
        Ractor.current[:rrs_worker_ready] = true
      end
    end

    # Prefill this worker's IES from the shareable fallback table so every
    # patched reader's first-tier probe hits immediately. Without this, each
    # reader pays a full IES miss + key? probe + SHAREABLE_FALLBACK probe on
    # every read (the fallback table is frozen and never changes in a
    # worker, so copying its key->value slots into the worker-local IES is
    # semantically transparent: same values, one tier sooner). Per-ractor
    # writes that happen later still override — the key? guard keeps any
    # value the worker already set for itself. Only non-nil fallback values
    # are copied (a nil fallback slot means "no fallback" by lookup
    # contract, and storing nil would fake a hit).
    def prefill_ies_from_fallback!
      fallback = RactorRailsShim::Registry.shareable_fallback
      storage = RactorRailsShim.storage
      fallback.each do |key, value|
        next if value.nil?
        storage[key] = value unless storage.key?(key)
      end
      nil
    end

    # Run the blocks registered via `RactorRailsShim.on_worker_boot`. These
    # re-arm per-Ractor state that cannot cross the Ractor boundary (e.g.
    # Rack::Attack's DSL check blocks — blocks created inside the worker are
    # worker-local Procs, callable here). Blocks are shareable (frozen at
    # registration); call order is registration order, once per worker.
    # Workers read the frozen WORKER_BOOT_BLOCKS snapshot (reassigned at
    # fallback-build time); main reads the live registry — though main never
    # runs them (main keeps its own live boot state).
    def run_worker_boot_blocks!
      blocks =
        if ::Ractor.main?
          RactorRailsShim::Registry.worker_boot_blocks
        else
          snapshot = begin
            ::RactorRailsShim::WORKER_BOOT_BLOCKS
          rescue ::NameError
            nil
          end
          snapshot || []
        end
      return nil if blocks.empty?
      blocks.each do |block|
        RactorRailsShim.__send__(:_swallow, "worker boot block") { block.call }
      end
      nil
    end

    def rebind_constants
      @bindings.each do |cpath, obj|
        parent = Object
        parts = cpath.split("::")
        parts[0...-1].each do |p|
          # Re-fetch the parent each iteration so concurrent setup (multiple
          # threads racing through setup_once! on the same worker) cannot
          # clobber a namespace module out from under us.
          parent = if parent.const_defined?(p, false)
            parent.const_get(p, false)
          else
            parent.const_set(p, Module.new)
          end
        end
        leaf = parts.last
        parent.const_set(leaf, obj) unless parent.const_defined?(leaf, false)
      end
    end
  end
end
