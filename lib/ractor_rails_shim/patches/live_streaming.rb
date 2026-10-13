# frozen_string_literal: true

# `RactorRailsShim::Patches::LiveStreaming` — the role object that owns the
# ActionController::Live worker-streaming patch.
#
# Background: streaming controllers (the Active Storage blob proxy route,
# `ActiveStorage::Blobs::ProxyController`, includes ActionController::Live)
# process the action on a POOL THREAD: `Live#process` calls
# `new_controller_thread { ... }` and then blocks on `@_response.await_commit`
# until the spawned thread commits the response. Two Ractor problems:
#
#   1. `ActionController::Live.live_thread_pool_executor` lazily SETS a class
#      ivar (`@live_thread_pool_executor ||= Concurrent::CachedThreadPool.new`)
#      — Ruby 4.0 forbids class-ivar writes from non-main Ractors
#      (Ractor::IsolationError).
#   2. Even with a worker-local pool, the spawned-thread hop deadlocks in
#      practice: any exception (or block) before `commit!` kills the pooled
#      thread (`abort_on_exception = true`), so `await_commit` never returns
#      and the worker request hangs forever.
#
# The patch (worker Ractors only): run the streaming action INLINE —
# `new_controller_thread` yields in the request thread instead of hopping to
# a pool thread. Upstream's own flow is then harmless on one thread: the
# `share_with(t1, ...)` block shares the request thread's state with itself,
# the action runs, `commit!` fires in its ensure, and `await_commit` returns
# immediately. Main keeps the upstream pool-thread behavior verbatim.
#
# Trade-off (documented): a worker loses true streaming concurrency — the
# response headers are not flushed before the body is generated. The bytes
# still stream through the Rack response body (Live::Buffer), so consumers
# (and the kino's body consumption) are unchanged.
#
# This object owns the idempotency flag (`@installed`). The facade method
# `_install_live_streaming_patch` (patches/core.rb) delegates here.

module RactorRailsShim
  module Patches
    module LiveStreaming
      @installed = false
      @mutex = Mutex.new

      module Overrides
        # Worker Ractors: run the streaming action on the request thread.
        # (No class-ivar pool read/write, no thread hop, no await_commit
        # deadlock.) Main: upstream pool-thread behavior.
        def new_controller_thread
          if defined?(::Ractor) && !::Ractor.main?
            yield
          else
            super
          end
        end
      end

      def self.install
        @mutex.synchronize do
          return true if @installed
          return true unless defined?(::ActionController::Live)

          ::ActionController::Live.prepend(Overrides)
          @installed = true
        end
        true
      end

      def self.installed?
        @installed
      end
    end
  end
end
