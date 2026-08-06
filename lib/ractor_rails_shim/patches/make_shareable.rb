# frozen_string_literal: true

# make_app_shareable! entry point + the SHAREABLE_CONSTANTS /
# SHAREABLE_CLASS_IVARS registrations for Devise / ActiveSupport / Warden.
#
# The graph-traversal, callable/lock replacement, shareable-fallback, and
# logger-neutralization machinery that used to live here was extracted to
# role objects (ShareabilityTraversal, FallbackBuilder, LoggerIONeutralizer,
# CallbackCapture, ActionDispatchStrategy, Freezers::*)
# in Issues #13/#22. Issue #31 deletes the facade delegations that forwarded
# to those role objects; the role objects are now called directly. This file
# keeps only the genuine public entry (`make_app_shareable!`) and the two
# constant registrations that must run at load time (before Devise /
# ActiveSupport / Warden are loaded).

module RactorRailsShim
  class << self
    # Devise defines several mutable module-level constants (Array/Hashes
    # populated at load time: mappings, strategies, url helpers, no_input
    # strategies). Worker Ractors read them (e.g. Devise::NO_INPUT in
    # mapping.rb), so they must be deep-frozen + made shareable before the
    # app graph is frozen. Added here; make_constant_shareable! resolves each
    # lazily once Devise is loaded.
    SHAREABLE_CONSTANTS.concat([
      "Devise::ALL",
      "Devise::CONTROLLERS",
      "Devise::ROUTES",
      "Devise::STRATEGIES",
      "Devise::URL_HELPERS",
      "Devise::NO_INPUT",
    ])

    # Class instance variables holding unshareable values that workers read
    # during request dispatch. Made Ractor-shareable (deep-frozen) at boot.
    SHAREABLE_CLASS_IVARS.concat([
      ["ActiveSupport::Editor", :@editors],
      ["Warden::Strategies", :@strategies],
    ])

    # Public API: make Rails.application shareable across Ractors. Delegates
    # to `RactorRailsShim::AppShareabilizer.make_shareable!(app)` (extracted
    # Step 22.6, Issue #22). See `AppShareabilizer` for the full pipeline
    # contract (precompute → freeze ivars → warm routes → neutralize logger
    # → replace procs → replace locks → make_shareable → build fallback).
    #
    # WARNING: this MUTATES the app object graph in place (replaces ivars).
    # The app becomes read-only (frozen). Do NOT call if you intend to keep
    # mutating the app (e.g. development reloading). Production-only.
    #
    # Returns the shareable app. Raises on failure (e.g. if a Proc can't be
    # replaced — add the missing constant to shareable_constants first).
    def make_app_shareable!(app)
      AppShareabilizer.make_shareable!(app)
    end
  end
end