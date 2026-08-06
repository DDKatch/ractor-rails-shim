# frozen_string_literal: true

# ConstReassign (Issue #46 Step 46.2): the $VERBOSE-suppressed const_set
# utility extracted from the facade's _reassign_shareable_const.
#
# The facade's _reassign_shareable_const calls ConstReassign.call, then
# updates Registry for the four known registries (SHAREABLE_FALLBACK,
# SHAREABLE_MATTR_DEFAULTS, ABSTRACT_REGISTRY, VIEW_CONTEXT_REGISTRY).
# Role objects (CallbackCapture, FallbackBuilder, AppShareabilizer) inject
# ConstReassign.method(:call) directly via the configure seam.

module RactorRailsShim
  module ConstReassign
    # Set a constant on target_module with $VERBOSE suppressed.
    # Returns the new value.
    def self.call(target_module, name, value)
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        target_module.const_set(name, value)
      ensure
        $VERBOSE = verbose
      end
      value
    end
  end
end
