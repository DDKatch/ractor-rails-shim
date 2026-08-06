# frozen_string_literal: true

# PreSpawnSteps (Issue #48): shared orchestration steps between
# prepare_for_ractors! and AppShareabilizer.make_shareable!. Both paths
# call the same three steps (apply shareable constants, freeze shareable
# class ivars, install framework patches). PreSpawnSteps owns these shared
# steps so adding a new shared step is one edit.
#
# prepare_for_ractors! calls PreSpawnSteps for the shared steps, then
# calls its unique steps (snapshot, url_helpers, freezers) directly.
#
# AppShareabilizer.make_shareable! calls PreSpawnSteps for the shared
# steps via its configured dependencies, then calls its unique steps
# (precompute, freeze callbacks, replace procs, make_shareable, build
# fallback) directly.

module RactorRailsShim
  module PreSpawnSteps
    class << self
      # Apply all registered shareable constants (deep-freeze).
      def apply_shareable_constants
        ConstantShareabilizer.apply!
      end

      # Freeze shareable class ivars on the registered classes.
      def freeze_shareable_class_ivars
        Freezers::ShareableClassIvarFreezer.call
      end

      # Dispatch all framework patches (idempotent).
      def install_framework_patches
        Installer.dispatch_all_framework_patches
      end
    end
  end
end
