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
            kind = kind.to_sym
            if RactorRailsShim.thread_mode? && kind == :process_action &&
               defined?(::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS)
              # Thread (Puma/Falcon) mode: the eager-load class_attribute leak
              # corrupts __callbacks, so ALWAYS replay the captured symbolic
              # filters (ignoring __callbacks entirely). Serving happens in the
              # main Ractor, where the worker-style empty-__callbacks path
              # below never triggers.
              table = ::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS
              action = (self.action_name rescue nil)
              action = action.to_sym if action
              entries = []
              k = self.class
              while k && k <= ::ActionController::Base
                rec = table[k.object_id]
                entries = rec + entries if rec
                k = k.superclass
              end
              unless entries.empty?
                applies = lambda do |e|
                  next false unless (e[:kind] == :before || e[:kind] == :after)
                  in_only = e[:only].nil? || (action && e[:only].include?(action))
                  not_except = e[:except].nil? || !(action && e[:except].include?(action))
                  in_only && not_except
                end
                result = nil
                halted = false
                entries.each do |e|
                  next unless e[:kind] == :before && applies.call(e)
                  send(e[:filter]) if respond_to?(e[:filter], true)
                  if respond_to?(:performed?) ? performed? : response_body
                    halted = true
                    break
                  end
                end
                result = (yield if block_given?) unless halted
                entries.each do |e|
                  next unless e[:kind] == :after && applies.call(e)
                  send(e[:filter]) if respond_to?(e[:filter], true)
                end
                return result
              end
            end
            callbacks = __callbacks[kind] if __callbacks
            if callbacks.nil? || callbacks.empty?
              # In a worker Ractor, class_attribute-backed `__callbacks`
              # falls back to the empty default (see class_attribute.rb /
              # make_shareable.rb), so controller `before_action` /
              # `after_action` filters are normally SKIPED. For
              # `:process_action` we replay the captured SYMBOL filters
              # (see make_shareable!#_capture_controller_callbacks!)
              # so actions that depend on a before_action (e.g. `set_post`
              # loading `@post`) render correctly. Proc/lambda filters
              # are not captured (self-capturing, unshareable) and are
              # skipped — a known limitation.
              if (RactorRailsShim.thread_mode? || !Ractor.main?) && kind.to_sym == :process_action &&
                 defined?(::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS)
                table = ::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS
                action = (self.action_name rescue nil)
                action = action.to_sym if action
                # Reconstruct this controller's callback list by walking its
                # ancestors (superclass-first). Each class recorded ONLY the
                # filters IT declared (via the set_callback interceptor), which
                # bypasses the eager-load class_attribute leak that otherwise
                # pollutes __callbacks.
                entries = []
                k = self.class
                while k && k <= ::ActionController::Base
                  rec = table[k.object_id]
                  entries = rec + entries if rec
                  k = k.superclass
                end
                unless entries.empty?
                  # A captured symbolic filter applies to this action unless
                  # constrained by `only:`/`except:`. `kind` (before/after)
                  # decides whether it wraps the action pre- or post-yield.
                  applies = lambda do |e|
                    next false unless (e[:kind] == :before || e[:kind] == :after)
                    in_only = e[:only].nil? || (action && e[:only].include?(action))
                    not_except = e[:except].nil? || !(action && e[:except].include?(action))
                    in_only && not_except
                  end
                  result = nil
                  halted = false
                  entries.each do |e|
                    next unless e[:kind] == :before && applies.call(e)
                    send(e[:filter]) if respond_to?(e[:filter], true)
                    # A before-filter that renders/redirects performs — halt the
                    # chain (as the real ActiveSupport::Callbacks machinery
                    # does) so the action is NOT run. Otherwise an action that
                    # depends on a performed before_action (e.g. Devise's
                    # verify_signed_out_user redirect) would render twice.
                    if respond_to?(:performed?) ? performed? : response_body
                      halted = true
                      break
                    end
                  end
                  result = (yield if block_given?) unless halted
                  entries.each do |e|
                    next unless e[:kind] == :after && applies.call(e)
                    send(e[:filter]) if respond_to?(e[:filter], true)
                  end
                  return result
                end
              end
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
