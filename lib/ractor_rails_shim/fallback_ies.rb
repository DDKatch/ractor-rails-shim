# frozen_string_literal: true

# Fallback IsolatedExecutionState when ActiveSupport is not available.
#
# The shim's string-eval'd patch methods reference the literal constant
# `ActiveSupport::IsolatedExecutionState` (no captured binding → callable
# from any Ractor). To avoid opening the ActiveSupport namespace from a
# third-party gem, the fallback is defined in the shim's own namespace
# (RactorRailsShim::FallbackIES) and aliased onto
# ActiveSupport::IsolatedExecutionState only when the real AS IES is absent.
# When AS is loaded, the real one wins untouched and no alias is created.
module RactorRailsShim
  module FallbackIES
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
end

# Alias onto ActiveSupport::IsolatedExecutionState only when the real AS IES
# is absent, so the shim's string-eval'd references resolve to the fallback
# without the shim opening the ActiveSupport namespace to define a module.
unless defined?(ActiveSupport::IsolatedExecutionState)
  module ActiveSupport
    IsolatedExecutionState = RactorRailsShim::FallbackIES
  end
end