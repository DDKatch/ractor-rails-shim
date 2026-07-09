# frozen_string_literal: true

# Fallback IsolatedExecutionState when ActiveSupport is not available.
# This is a simple thread-local storage that mimics the ActiveSupport API
# enough for the shim to work. In production (with Rails loaded), the real
# ActiveSupport::IsolatedExecutionState is used instead.
module ActiveSupport
  module IsolatedExecutionState
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
end unless defined?(ActiveSupport::IsolatedExecutionState)