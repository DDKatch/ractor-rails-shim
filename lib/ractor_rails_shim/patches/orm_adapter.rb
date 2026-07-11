# frozen_string_literal: true

# Patch OrmAdapter::ToAdapter#to_adapter. The original memoizes the adapter on
# the model CLASS via `@_to_adapter ||= self::OrmAdapter.new(self)`. A worker
# Ractor cannot set an instance variable on a class/module, so it raises
# "Ractor::IsolationError: can not set instance variables of classes/modules by
# non-main Ractors". Route the per-class cache through IsolatedExecutionState,
# keyed by the class's (stable, shared) object_id. Each Ractor builds its own
# adapter and caches it locally; the adapter only holds a reference to the
# (shared) model class, so no cross-boundary objects are involved.

module RactorRailsShim
  class << self
    def _install_orm_adapter_patch
      return if @orm_adapter_patched
      @orm_adapter_patched = true
      _register_patch :orm_adapter, "8.1"
      return unless defined?(::OrmAdapter::ToAdapter)

      ::OrmAdapter::ToAdapter.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def to_adapter
          key = :"ractor_rails_shim_orm_adapter_\#{object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          adapter = self::OrmAdapter.new(self)
          ActiveSupport::IsolatedExecutionState[key] = adapter
          adapter
        end
      RUBY
    end
  end
end
