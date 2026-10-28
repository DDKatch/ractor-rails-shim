# frozen_string_literal: true

# `RactorRailsShim::Patches::DependenciesInterlock` — the role object that
# owns the ActiveSupport::Dependencies interlock reader patch.
#
# Background: `ActiveSupport::Dependencies.interlock` is a class-level
# `attr_accessor` backed by a class ivar set at load time
# (`@interlock = Interlock.new`). The Interlock wraps a
# Concurrency::ShareLock (mutexes) — unshareable. Ruby 4.0 forbids reading
# UNSHAREABLE values from class ivars of classes/modules in non-main
# Ractors (Ractor::IsolationError), so any worker-side
# `ActiveSupport::Dependencies.interlock` read dies. The streaming
# controller path (`ActionController::Live#process` calls
# `Dependencies.interlock.running { ... }`) hits exactly this on every
# worker-side streaming request — e.g. the Active Storage blob proxy route
# (row 127). Regular worker requests don't: the kino (and the shim's
# production stack) drop the ActionDispatch::Executor middleware, which is
# the only other interlock consumer.
#
# The patch replaces the reader with a Ractor-aware method:
#   - MAIN: returns the upstream class ivar (100% upstream semantics).
#   - Workers: a per-Ractor Interlock from IsolatedExecutionState. Workers
#     never reload (the graph is frozen), so the lock never contends; a
#     per-Ractor lock preserves the API without sharing unshareable lock
#     objects. The upstream writer (`interlock=`) is untouched.
#
# This object owns the idempotency flag (`@installed`). The facade method
# `_install_dependencies_interlock_patch` (patches/core.rb) delegates here.

module RactorRailsShim
  module Patches
    module DependenciesInterlock
      @installed = false
      @mutex = Mutex.new

      def self.install
        @mutex.synchronize do
          return true if @installed
          return true unless defined?(::ActiveSupport::Dependencies::Interlock)

          ::ActiveSupport::Dependencies.singleton_class.class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def interlock
              if ::Ractor.main?
                @interlock
              else
                ::RactorRailsShim.storage[:rrs_dependencies_interlock] ||=
                  ::ActiveSupport::Dependencies::Interlock.new
              end
            end
          RUBY

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
