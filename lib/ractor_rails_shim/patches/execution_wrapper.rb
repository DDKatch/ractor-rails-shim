# frozen_string_literal: true

# Patch ActiveSupport::ExecutionWrapper.active_key to not write a class
# ivar from a worker Ractor. The original is `@active_key ||= :"..."`,
# a raw class-ivar write — illegal from non-main Ractors. The value is a
# frozen Symbol (pure function of object_id), so we route the cache
# through IES (per-Ractor; each Ractor computes the same Symbol from the
# same object_id, so the cached value is identical across Ractors).
# ExecutionWrapper is the base for Reloader/Executor; `active_key` is
# called on every request via ActionDispatch::Executor middleware.
#
# Also patches ActiveSupport::Callbacks#run_callbacks to tolerate nil
# __callbacks, and ActiveSupport::Notifications.notifier to not read @notifier.

module RactorRailsShim
  class << self
    def install_execution_wrapper
      return if @exec_wrapper_patched
      @exec_wrapper_patched = true
      _register_patch :execution_wrapper, "8.1"
      if defined?(::ActiveSupport::ExecutionWrapper)
        patch_execution_wrapper!
      else
        @ew_tp = TracePoint.new(:class) do |trace|
          if defined?(::ActiveSupport::ExecutionWrapper) && !@exec_wrapper_registry_patched
            @ew_tp.disable
            patch_execution_wrapper!
          end
        end
        @ew_tp.enable
      end
    end

    def patch_execution_wrapper!
      return if @exec_wrapper_registry_patched
      @exec_wrapper_registry_patched = true
      ew = ::ActiveSupport::ExecutionWrapper
      key = :ractor_rails_shim_exec_wrapper_active_key
      key_str = key.inspect
      # active_key returns :"active_execution_wrapper_<object_id>"; a frozen
      # Symbol is shareable. Compute it once per Ractor and cache in IES.
      ew.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def active_key
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          sym = :"active_execution_wrapper_\#{object_id}"
          ActiveSupport::IsolatedExecutionState[#{key_str}] = sym
          sym
        end
      RUBY

      # Patch ActiveSupport::Callbacks#run_callbacks to tolerate a nil
      # __callbacks (the case in worker Ractors whose class_attribute fallback
      # couldn't be made shareable because callback chains hold frozen,
      # self-capturing Procs). For a frozen, read-only shared app the boot-time
      # callbacks (ExecutionContext push/pop, CurrentAttributes clear) already
      # ran in the main Ractor at boot; worker Ractors don't need to re-run
      # them per request (CurrentAttributes/ExecutionContext are thread-local,
      # hence per-Ractor, and start empty in a fresh worker). When __callbacks
      # is nil, run_callbacks just yields the block — matching the empty-chain
      # fast path in the original.
      if defined?(::ActiveSupport::Callbacks)
        ::ActiveSupport::Callbacks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def run_callbacks_with_nil_safe(kind, type = nil)
            callbacks = __callbacks[kind.to_sym] if __callbacks
            if callbacks.nil? || callbacks.empty?
              yield if block_given?
            else
              run_callbacks_without_nil_safe(kind, type) { yield if block_given? }
            end
          end
          alias_method :run_callbacks_without_nil_safe, :run_callbacks
          alias_method :run_callbacks, :run_callbacks_with_nil_safe
        RUBY
      end

      # Patch ActiveSupport::Notifications.notifier to not read the @notifier
      # class ivar from a worker Ractor. The original is `attr_accessor
      # :notifier` with `@notifier = Fanout.new` set at module load — a raw
      # class ivar holding a Fanout (which has a Mutex + subscriber Procs,
      # both unshareable). Workers get their own per-Ractor Fanout (no
      # subscribers — instrumentation is a no-op in workers, which is correct
      # for a read-only shared app where log subscribers already ran in main).
      # `notifier` is read by `instrumenter` (per-request via Rails::Rack::Logger).
      if defined?(::ActiveSupport::Notifications)
        notif = ::ActiveSupport::Notifications
        nkey = :ractor_rails_shim_notifications_notifier
        nkey_str = nkey.inspect
        notif.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def notifier
            v = ActiveSupport::IsolatedExecutionState[#{nkey_str}]
            return v unless v.nil?
            if Ractor.main? && instance_variable_defined?(:@notifier)
              @notifier
            else
              built = ActiveSupport::Notifications::Fanout.new
              ActiveSupport::IsolatedExecutionState[#{nkey_str}] = built
              built
            end
          end
        RUBY
      end
    end
  end
end
