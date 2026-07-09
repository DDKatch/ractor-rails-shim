# frozen_string_literal: true

# Patch Warden::Hooks lazy class-ivar accessors (@_on_request ||= [] etc).
# Warden middleware holds 6 lazy-init class ivars for callback arrays.
# make_app_shareable! freezes the middleware instance; the ||= lazy init
# tries to WRITE on the frozen instance → IsolationError in workers.
# The callbacks (Procs) were registered at boot and already ran in main;
# workers treat them as empty (correct for a read-only shared app).

module RactorRailsShim
  class << self
    def _install_warden_hooks_patch
      return if @warden_patched
      @warden_patched = true
      _register_patch :warden_hooks, "8.1"
      return unless defined?(::Warden::Hooks)
      ::Warden::Hooks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _after_set_user
          if Ractor.main? && instance_variable_defined?(:@_after_set_user)
            @_after_set_user
          else
            []
          end
        end
        def _before_failure
          if Ractor.main? && instance_variable_defined?(:@_before_failure)
            @_before_failure
          else
            []
          end
        end
        def _after_failed_fetch
          if Ractor.main? && instance_variable_defined?(:@_after_failed_fetch)
            @_after_failed_fetch
          else
            []
          end
        end
        def _before_logout
          if Ractor.main? && instance_variable_defined?(:@_before_logout)
            @_before_logout
          else
            []
          end
        end
        def _on_request
          if Ractor.main? && instance_variable_defined?(:@_on_request)
            @_on_request
          else
            []
          end
        end
      RUBY
    end
  end
end
