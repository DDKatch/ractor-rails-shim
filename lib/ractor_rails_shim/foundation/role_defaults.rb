# frozen_string_literal: true

# RoleDefaults — DRY mixin for the three shared default-proc patterns
# used by every role object with a configure seam (Issue #44, POODR §8e).
#
# Every role with a `funnel` seam copies:
#   @funnel || RactorRailsShim::Funnel.method(:swallow)
# Every role with a `safe_const_get` seam copies:
#   @safe_const_get || RactorRailsShim::ConstantShareabilizer.method(:safe_const_get)
# Every role with a `reassign_shareable_const` seam copies:
#   @reassign_shareable_const || RactorRailsShim.method(:_reassign_shareable_const)
#
# `RoleDefaults` centralises the three defaults; each role `extend`s it
# and its `funnel` / `safe_const_get` / `reassign_shareable_const` reader
# calls `default_funnel` etc. The boilerplate collapses to one definition.
#
# Usage in a role module:
#
#   module MyRole
#     extend RoleDefaults
#
#     @funnel = nil
#     @safe_const_get = nil
#
#     def self.configure(funnel: nil, safe_const_get: nil)
#       @funnel = funnel
#       @safe_const_get = safe_const_get
#     end
#
#     def self.reset_configuration
#       @funnel = nil
#       @safe_const_get = nil
#     end
#
#     def self.funnel
#       @funnel || default_funnel
#     end
#
#     def self.safe_const_get
#       @safe_const_get || default_safe_const_get
#     end
#   end
#
module RactorRailsShim
  module RoleDefaults
    def default_funnel
      RactorRailsShim::Funnel.method(:swallow)
    end

    def default_safe_const_get
      RactorRailsShim::ConstantShareabilizer.method(:safe_const_get)
    end

    def default_reassign_shareable_const
      RactorRailsShim.method(:_reassign_shareable_const)
    end
  end
end
