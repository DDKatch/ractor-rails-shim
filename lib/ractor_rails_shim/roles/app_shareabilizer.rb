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
# The collaborators are reached through the configure seam, defaulting to
# the facade lookups so existing call sites keep working (Issue #23, POODR
# §2 Dependencies). Issue #36b (Round 4): the SHAREABLE_APP stash lives on
# AppShareabilizer itself (the role owns its output state), NOT on the
# facade. The ConstantShareabilizer.applied? gate lives on the role.

module RactorRailsShim
  module AppShareabilizer
    @apply_shareable_constants = nil
    @install_all_framework_patches = nil
    @precompute_lazy_ivars = nil
    @precompute_propshaft = nil
    @generate_ar_attribute_methods = nil
    @warm_attribute_method_patterns = nil
    @freeze_declared_callbacks = nil
    @freeze_shareable_class_ivars = nil
    @warm_journey_routes = nil
    @neutralize_logger_io = nil
    @replace_unshareable_procs = nil
    @replace_locks_and_concurrent_maps = nil
    @build_shareable_fallback = nil
    @make_shareable_fn = nil
    @reassign_shareable_const = nil

    def self.configure(apply_shareable_constants: nil, install_all_framework_patches: nil,
                       precompute_lazy_ivars: nil, precompute_propshaft: nil,
                       generate_ar_attribute_methods: nil, warm_attribute_method_patterns: nil,
                       freeze_declared_callbacks: nil, freeze_shareable_class_ivars: nil,
                       warm_journey_routes: nil, neutralize_logger_io: nil,
                       replace_unshareable_procs: nil, replace_locks_and_concurrent_maps: nil,
                       build_shareable_fallback: nil, make_shareable_fn: nil,
                       reassign_shareable_const: nil)
      @apply_shareable_constants = apply_shareable_constants
      @install_all_framework_patches = install_all_framework_patches
      @precompute_lazy_ivars = precompute_lazy_ivars
      @precompute_propshaft = precompute_propshaft
      @generate_ar_attribute_methods = generate_ar_attribute_methods
      @warm_attribute_method_patterns = warm_attribute_method_patterns
      @freeze_declared_callbacks = freeze_declared_callbacks
      @freeze_shareable_class_ivars = freeze_shareable_class_ivars
      @warm_journey_routes = warm_journey_routes
      @neutralize_logger_io = neutralize_logger_io
      @replace_unshareable_procs = replace_unshareable_procs
      @replace_locks_and_concurrent_maps = replace_locks_and_concurrent_maps
      @build_shareable_fallback = build_shareable_fallback
      @make_shareable_fn = make_shareable_fn
      @reassign_shareable_const = reassign_shareable_const
    end

    def self.reset_configuration
      @apply_shareable_constants = nil
      @install_all_framework_patches = nil
      @precompute_lazy_ivars = nil
      @precompute_propshaft = nil
      @generate_ar_attribute_methods = nil
      @warm_attribute_method_patterns = nil
      @freeze_declared_callbacks = nil
      @freeze_shareable_class_ivars = nil
      @warm_journey_routes = nil
      @neutralize_logger_io = nil
      @replace_unshareable_procs = nil
      @replace_locks_and_concurrent_maps = nil
      @build_shareable_fallback = nil
      @make_shareable_fn = nil
      @reassign_shareable_const = nil
    end

    def self.apply_shareable_constants
      @apply_shareable_constants || RactorRailsShim::ConstantShareabilizer.method(:apply!)
    end

    def self.install_all_framework_patches
      @install_all_framework_patches || RactorRailsShim::Installer.method(:dispatch_all_framework_patches)
    end

    def self.precompute_lazy_ivars
      @precompute_lazy_ivars || RactorRailsShim::ShareabilityTraversal.method(:precompute_lazy_ivars)
    end

    def self.precompute_propshaft
      @precompute_propshaft || RactorRailsShim.method(:_precompute_propshaft!)
    end

    def self.generate_ar_attribute_methods
      @generate_ar_attribute_methods || RactorRailsShim::ShareabilityTraversal.method(:generate_ar_attribute_methods!)
    end

    def self.warm_attribute_method_patterns
      @warm_attribute_method_patterns || RactorRailsShim::ShareabilityTraversal.method(:warm_attribute_method_patterns!)
    end

    def self.freeze_declared_callbacks
      @freeze_declared_callbacks || RactorRailsShim::CallbackCapture.method(:freeze_declared_callbacks!)
    end

    def self.freeze_shareable_class_ivars
      @freeze_shareable_class_ivars || RactorRailsShim::Freezers::ShareableClassIvarFreezer.method(:call)
    end

    def self.warm_journey_routes
      @warm_journey_routes || RactorRailsShim.method(:_warm_journey_routes!)
    end

    def self.neutralize_logger_io
      @neutralize_logger_io || RactorRailsShim::LoggerIONeutralizer.method(:call)
    end

    def self.replace_unshareable_procs
      @replace_unshareable_procs || RactorRailsShim::ShareabilityTraversal.method(:replace_unshareable_procs!)
    end

    def self.replace_locks_and_concurrent_maps
      @replace_locks_and_concurrent_maps || RactorRailsShim::ShareabilityTraversal.method(:replace_locks_and_concurrent_maps!)
    end

    def self.build_shareable_fallback
      @build_shareable_fallback || RactorRailsShim::FallbackBuilder.method(:build!)
    end

    def self.make_shareable_fn
      @make_shareable_fn || Ractor.method(:make_shareable)
    end

    def self.reassign_shareable_const
      @reassign_shareable_const || RactorRailsShim.method(:_reassign_shareable_const)
    end

    # Make the app Ractor-shareable. App is mutated in place (frozen).
    # Returns the same (now-frozen) app — Ruby freeze-style. Callers must
    # not assume a new object.
    def self.make_shareable!(app)
      apply_shareable_constants.call unless RactorRailsShim::ConstantShareabilizer.applied?
      install_all_framework_patches.call
      precompute_lazy_ivars.call(app)
      precompute_propshaft.call(app)
      generate_ar_attribute_methods.call
      warm_attribute_method_patterns.call
      freeze_declared_callbacks.call
      freeze_shareable_class_ivars.call
      warm_journey_routes.call
      neutralize_logger_io.call(app)
      replace_unshareable_procs.call(app)
      replace_locks_and_concurrent_maps.call(app)
      make_shareable_fn.call(app)
      stash!(app)
      build_shareable_fallback.call
      app
    end

    # One-shot stash of the app as SHAREABLE_APP on this role module.
    # Idempotent: first call wins (via const_defined? guard). Main-Ractor-
    # only by contract — workers must not reassign the constant. Returns
    # the app. Issue #36b: the constant lives on AppShareabilizer, not the
    # facade; the reassign_shareable_const seam is bypassed because it
    # writes to the facade, not the role.
    def self.stash!(app)
      return app if const_defined?(:SHAREABLE_APP, false)
      return app unless Ractor.main?
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        const_set(:SHAREABLE_APP, app)
      ensure
        $VERBOSE = verbose
      end
      @stashed = true
      app
    end

    def self.stashed?
      @stashed
    end

    def self.reset_stashed!
      @stashed = false
      remove_const(:SHAREABLE_APP) if const_defined?(:SHAREABLE_APP, false)
    end
  end
end