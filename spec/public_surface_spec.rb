# frozen_string_literal: true

# Public-surface spec for RactorRailsShim (Issue #31, step 31.4).
#
# Pins the genuine public singleton methods that remain on the
# RactorRailsShim facade after the Issue #31 cleanup. The facade shrank
# from ~48 delegations to the genuine entries listed below; everything
# else moved to role objects (ConstantShareabilizer, Freezers::*,
# Installer, AppShareabilizer, etc.) and is called directly.
#
# The genuine entries are:
#   - install / installed?                   install entry + idempotency
#   - prepare_for_ractors!                   pre-worker-boot lifecycle
#   - make_app_shareable!                    app freeze + shareability
#   - worker_app!                            shareable Rack app factory
#   - capture_app_constants!                Zeitwerk name capture
#   - make_constant_shareable!               per-constant shareability
#   - shareable_constants                    public registry reader
#   - version_policy / version_policy=        version-mismatch policy
#   - applicable_patches                      diagnostic patch report
#   - _register_patch                         version-tagged patch registration
#   - thread_mode? / thread_mode=             run-mode config (delegates to RunMode)
#   - debug? / debug=                         funnel verbosity (delegates to Funnel)
#   - storage                                active storage impl (delegates to Storage)
#   - _swallow                                funnel (delegates to Funnel.swallow)
#   - _reassign_shareable_const               constant reassignment utility
#   - _install_active_model_attribute_patch   dispatcher entry (auto-discovered)
#   - _install_hash_compute_if_absent_patch   dispatcher entry (auto-discovered)
#   - the per-concern install_* + _install_*_patch methods defined by patch files
#
# Run: ruby -Ilib -Ispec spec/public_surface_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class PublicSurfaceSpec < Minitest::Spec
  # The genuine public entry points (no underscore, no bang unless mutating).
  GENUINE_PUBLIC = %i[
    install
    installed?
    prepare_for_ractors!
    make_app_shareable!
    worker_app!
    capture_app_constants!
    make_constant_shareable!
    shareable_constants
    version_policy
    version_policy=
    applicable_patches
    thread_mode?
    thread_mode=
    debug?
    debug=
    storage
  ].freeze

  # Genuine private/utility entries (leading underscore, no bang unless
  # mutating). These stay on the facade.
  GENUINE_PRIVATE = %i[
    _register_patch
    _reassign_shareable_const
    _swallow
    _install_active_model_attribute_patch
    _install_hash_compute_if_absent_patch
    _check_version_support
    _version_mismatch
  ].freeze

  GENUINE_PUBLIC.each do |m|
    it "RactorRailsShim.#{m} is defined (genuine public entry)" do
      assert RactorRailsShim.respond_to?(m),
             "RactorRailsShim.#{m} should be defined (genuine public entry)"
    end
  end

  GENUINE_PRIVATE.each do |m|
    it "RactorRailsShim.#{m} is defined (genuine private/utility entry)" do
      assert RactorRailsShim.respond_to?(m, true),
             "RactorRailsShim.#{m} should be defined (private)"
    end
  end

  # The deleted facade delegations must NOT be present.
  DELETED = %i[
    install_shareable_constants
    _apply_shareable_constants!
    _make_value_shareable
    _safe_const_get
    split_const_path
    _install_all_framework_patches
    _freeze_active_record_class_ivars!
    _freeze_global_class_ivars!
    _freeze_global_constants!
    _freeze_messages_constants!
    _warm_active_record_class_caches!
    _freeze_shareable_class_ivars!
    _freeze_declared_callbacks!
    _record_declared_callback
    _install_callback_declaration_capture!
    _read_action_filter_constraints
    _read_ivar_or_warn
    _collect_controller_classes
    _neutralize_logger_io!
    _build_shareable_fallback!
    _try_make_shareable
    _shareable_copy
    _precompute_lazy_ivars
    _generate_ar_attribute_methods!
    _warm_attribute_method_patterns!
    _replace_unshareable_procs!
    _introspectable?
    _collect_procs
    _each_ivar_and_child
    _enumerable_but_not_basic?
    _replace_one_proc
    _strategy_replacement_for
    _replace_locks_and_concurrent_maps!
  ].freeze

  DELETED.each do |m|
    it "RactorRailsShim.#{m} is NOT defined (deleted in Issue #31)" do
      refute RactorRailsShim.respond_to?(m, true),
             "RactorRailsShim.#{m} should be deleted (was a facade delegation)"
    end
  end
end