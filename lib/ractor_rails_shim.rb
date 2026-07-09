# frozen_string_literal: true

require_relative "ractor_rails_shim/version"

# A monkey-patch shim that reroutes Rails' class-level instance variable
# accessors through ActiveSupport::IsolatedExecutionState, which is
# Ractor-safe. Full implementation in patches.rb (added in a later commit).
module RactorRailsShim
  class << self
    def install
      # Implemented in patches.rb
      raise NotImplementedError, "require \"ractor_rails_shim/patches\" first"
    end

    def installed?
      @installed ||= false
    end
  end
end
