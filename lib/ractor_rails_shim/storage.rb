# frozen_string_literal: true

# Storage role (Issue #14, Step 14.1): a pluggable key-value store contract
# (`[]`, `[]=`, `key?`, `delete`) with two implementations:
#
#   * `Storage::IES`        — delegates to ActiveSupport::IsolatedExecutionState.
#   * `Storage::ThreadLocal` — the former `FallbackIES` body (a thread-local
#     Hash). Used only when AS is absent.
#
# `RactorRailsShim.storage` is set once at load time: IES when AS is loaded,
# ThreadLocal otherwise. The eval'd method bodies in the patch files route
# through `RactorRailsShim.storage[...]` instead of the literal
# `ActiveSupport::IsolatedExecutionState[...]`, so the shim no longer needs to
# open the ActiveSupport namespace to alias the fallback onto it (Step 14.3
# deletes that namespace patch).
#
# The contract is intentionally minimal: the patch sites only use `[]`, `[]=`,
# `key?`, and (rarely) `delete`. `clear` is provided on ThreadLocal for
# spec/parity with the former FallbackIES API but is not part of the
# cross-implementation contract.

module RactorRailsShim
  module Storage
    # Delegates to the real ActiveSupport::IsolatedExecutionState when AS is
    # loaded. Methods are class methods on the module's singleton class so
    # callers do `Storage::IES[key]`.
    module IES
      class << self
        def [](key)
          ActiveSupport::IsolatedExecutionState[key]
        end

        def []=(key, value)
          ActiveSupport::IsolatedExecutionState[key] = value
        end

        def key?(key)
          ActiveSupport::IsolatedExecutionState.key?(key)
        end

        def delete(key)
          ActiveSupport::IsolatedExecutionState.delete(key)
        end
      end
    end

    # Thread-local fallback: the former `FallbackIES` body. A per-thread Hash
    # stored under a well-known key on Thread.current. Provides `clear` for
    # spec/parity (not part of the cross-implementation contract).
    module ThreadLocal
      KEY = :active_support_execution_state_fallback

      class << self
        def [](key)
          Thread.current[KEY]&.[](key)
        end

        def []=(key, value)
          (Thread.current[KEY] ||= {})[key] = value
        end

        def key?(key)
          Thread.current[KEY]&.key?(key)
        end

        def delete(key)
          Thread.current[KEY]&.delete(key)
        end

        def clear
          Thread.current[KEY] = nil
        end
      end
    end

    # Select once at load: IES when AS is loaded, ThreadLocal otherwise.
    @storage =
      if defined?(::ActiveSupport::IsolatedExecutionState)
        IES
      else
        ThreadLocal
      end

    class << self
      # The active storage implementation (either `Storage::IES` or
      # `Storage::ThreadLocal`). Exposed as `RactorRailsShim.storage` by the
      # facade (defined in `patches.rb`).
      attr_reader :storage
    end
  end

  class << self
    # The active storage implementation. Patch sites route through this so the
    # shim doesn't open the ActiveSupport namespace to alias the fallback.
    def storage
      Storage.storage
    end
  end
end