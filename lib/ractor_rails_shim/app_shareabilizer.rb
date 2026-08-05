# frozen_string_literal: true

# `RactorRailsShim::AppShareabilizer` — the orchestrator role that composes
# the shareability pipeline for `make_app_shareable!` (extracted from the
# facade god module in Step 22.6, Issue #22; POODR §1 SRP).
#
# The pipeline (in order):
#   1.  _apply_shareable_constants!         freeze registered constants
#   2.  _install_all_framework_patches      idempotent full patch set
#   3.  _precompute_lazy_ivars(app)         mutate app before freezing
#   4.  _precompute_propshaft!(app)         warm propshaft assets
#   5.  _generate_ar_attribute_methods!     force AR method generation in main
#   6.  _warm_attribute_method_patterns!    warm ActiveModel caches
#   7.  _freeze_declared_callbacks!         freeze the captured callback table
#   8.  _freeze_shareable_class_ivars!      freeze SHAREABLE_CLASS_IVARS
#   9.  _warm_journey_routes!               warm the routes simulator
#   10. _neutralize_logger_io!(app)         detach logger IO (LoggerIONeutralizer)
#   11. _replace_unshareable_procs!(app)    Proc → callable (ShareabilityTraversal)
#   12. _replace_locks_and_concurrent_maps!(app)  Mutex/Map → NoOpLock/Hash
#   13. Ractor.make_shareable(app)          the freeze
#   14. stash SHAREABLE_APP (main only)     constant for worker reads
#   15. _build_shareable_fallback!          framework config fallback
#
# Each step is a facade method that delegates to its role object
# (ShareabilityTraversal, LoggerIONeutralizer, CallbackCapture,
# FallbackBuilder, etc.). AppShareabilizer is the composition root that
# sequences them; the facade `make_app_shareable!` delegates to it until
# Issue #31 removes it.
#
# The collaborators are reached through the facade (Issue #23 will inject
# them as constructor args). The `_apply_shareable_constants!` gate
# (`@shareable_constants_done`) and the `SHAREABLE_APP` stash still live
# on the facade; Issue #24/#29 will move them to their owners.

module RactorRailsShim
  module AppShareabilizer
    # Make `app` Ractor-shareable. Replaces every self-capturing Proc in
    # the app graph with a callable object, every Mutex/Monitor with a
    # NoOpLock, every Concurrent::Map with a frozen Hash, then calls
    # `Ractor.make_shareable`. Must run in the main Ractor after
    # `prepare_for_ractors!` and before spawning workers.
    #
    # WARNING: this MUTATES the app object graph in place (replaces
    # ivars). The app becomes read-only (frozen). Do NOT call if you
    # intend to keep mutating the app (e.g. development reloading).
    #
    # Returns the shareable app (same object, now frozen). Raises on
    # failure (e.g. if a Proc can't be replaced — add the missing
    # constant to shareable_constants first).
    def self.make_shareable!(app = Rails.application)
      # Shareable constants + Rack::Request + Inflector + ParameterEncoding +
      # PathRegistry + AbstractController + error_reporter + LookupContext +
      # I18n + Template::Handlers + ExecutionContext + Request param parsers.
      RactorRailsShim._apply_shareable_constants! unless RactorRailsShim.instance_variable_get(:@shareable_constants_done)
      # Install (or re-run, idempotently) the full framework-patch set. Most
      # are already applied by prepare_for_ractors!; this guarantees every
      # patch is present after full boot even if prepare_for_ractors! ran
      # before some classes were loaded.
      RactorRailsShim._install_all_framework_patches
      # Pre-compute lazy ivars BEFORE freezing (they mutate the app).
      RactorRailsShim._precompute_lazy_ivars(app)
      RactorRailsShim._precompute_propshaft!(app)
      # Force ActiveRecord attribute-method generation in the MAIN Ractor
      # for every loaded model. AR defines these lazily on first
      # instantiation; if left undone, a worker Ractor's first `Post.new` /
      # record load re-enters `define_attribute_methods`, which locks
      # `GeneratedAttributeMethods::LOCK` — a `Monitor` created in the main
      # Ractor and therefore non-shareable — raising Ractor::IsolationError.
      # Generating here (where the Monitor is reachable) sets
      # `@attribute_methods_generated = true` on the shared, frozen classes
      # so workers skip the lock entirely.
      RactorRailsShim._generate_ar_attribute_methods!
      # Warm + freeze ActiveModel's per-class `attribute_method_patterns_
      # cache` (and `attribute_method_matchers`) in MAIN for every loaded
      # model. See ShareabilityTraversal#warm_attribute_method_patterns!
      # for why: a worker Ractor reading these lazy class ivars (Array of
      # [Regexp, Symbol], but mutable => unshareable) during
      # `redirect_to @post` -> `respond_to?` raises Ractor::IsolationError.
      RactorRailsShim._warm_attribute_method_patterns!
      # Capture each controller's OWN declared `process_action` symbol
      # filters (before_action / after_action) into a shareable table so
      # worker Ractors can replay them. See CallbackCapture for the full
      # rationale (the eager-load class_attribute callback-chain leak).
      RactorRailsShim._freeze_declared_callbacks!
      # Warm + cache the routes' @ast / @simulator on the live graph. This
      # MUST run AFTER the route precompute above (which reloads/resets the
      # routes) and BEFORE _replace_unshareable_procs! /
      # Ractor.make_shareable below: the proc-replacement pass rewrites the
      # Route constraint Procs held in the simulator's @memos, and the
      # freeze then shares the whole thing so worker Ractors read the
      # cached, frozen simulator via the original Routes#simulator (no
      # per-worker rebuild). See action_dispatch.rb.
      RactorRailsShim._freeze_shareable_class_ivars!
      RactorRailsShim._warm_journey_routes!
      # Neutralize the app's logger IO so Ractor.make_shareable doesn't
      # freeze $stdout/$stderr (freezing STDOUT breaks the process's own
      # output). Workers build their own per-Ractor Rails.logger, so the
      # app-instance logger is unused post-freeze; redirect its logdev to
      # a fresh StringIO sink (which is safely freezable).
      RactorRailsShim._neutralize_logger_io!(app)
      RactorRailsShim._replace_unshareable_procs!(app)
      RactorRailsShim._replace_locks_and_concurrent_maps!(app)
      Ractor.make_shareable(app)
      # Stash the now-shareable app in a constant so worker Ractors can
      # read `Rails.application` (e.g. Propshaft::Helper reads
      # `Rails.application.assets`, and various gems call Rails.application
      # internally). The shared app is frozen (read-only), so returning it
      # from worker Ractors is safe — they only read from it, never mutate.
      if Ractor.main?
        RactorRailsShim._reassign_shareable_const(:SHAREABLE_APP, app) unless RactorRailsShim.const_defined?(:SHAREABLE_APP)
      end
      # Build the framework-config fallback AFTER the app is frozen. The
      # fallback makes class_attribute / mattr_accessor values shareable;
      # some of those values reference the app graph (e.g. config objects
      # that point back at Rails.application). Doing this after the app is
      # already shareable means Ractor.make_shareable on the config values
      # is a no-op for the app portion (already frozen) — avoiding a
      # "can't modify frozen app" error when precompute wrote to it.
      # (prepare_for_ractors!, which also builds the fallback, is a no-op
      # now via @fallback_built.)
      RactorRailsShim._build_shareable_fallback!
      app
    end
  end
end