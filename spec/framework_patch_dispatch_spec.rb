# frozen_string_literal: true

# Spec for the Open/Closed refactor of _install_all_framework_patches.
#
# The dispatcher must auto-discover every _install_*_patch singleton method
# instead of hardcoding a literal call list. Adding a new patch method should
# NOT require editing _install_all_framework_patches — the method table IS
# the registry.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class FrameworkPatchDispatchSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # The set of _install_*_patch methods that are intentionally called from
  # OTHER install paths (not from the dispatcher). They must be excluded
  # from auto-discovery.
  NON_DISPATCHED = %i[
    _install_callbacks_nil_safe_patch
    _install_notifications_notifier_patch
    _install_with_empty_template_cache_patch
  ].freeze

  it "auto-discovers a newly added _install_*_patch method" do
    called = []
    RactorRailsShim.define_singleton_method(:_install_test_auto_dispatch_patch) do
      called << :test_auto_dispatch
    end

    RactorRailsShim._install_all_framework_patches

    assert_includes called, :test_auto_dispatch,
                    "dispatcher should auto-discover _install_test_auto_dispatch_patch"
  ensure
    RactorRailsShim.singleton_class.remove_method(:_install_test_auto_dispatch_patch) rescue nil
  end

  # Read the source of _install_all_framework_patches from the file.
  def dispatcher_source
    file, line = RactorRailsShim.method(:_install_all_framework_patches).source_location
    src = File.readlines(file)
    src[(line - 1)..].take_while { |l| !l.strip.eql?("end") }.join
  end

  it "does not call NON_DISPATCHED patches from the dispatcher" do
    # These are called from their parent install methods, not the dispatcher.
    NON_DISPATCHED.each do |m|
      refute dispatcher_source.include?(m.to_s),
             "#{m} should not be called from _install_all_framework_patches"
    end
  end

  it "dispatcher source contains no hardcoded _install_*_patch call lines" do
    # After the refactor, the dispatcher should iterate the method table,
    # not list individual method names.
    hardcoded = dispatcher_source.scan(/^\s+_install_\w+_patch$/)
    assert hardcoded.empty?,
           "dispatcher should not hardcode _install_*_patch calls, found: #{hardcoded.inspect}"
  end

  # --- Behavioral equivalence: same set of patches dispatched as before ---
  #
  # The original hardcoded list called exactly 75 _install_*_patch methods.
  # The introspection-based dispatch must call the same set (all _install_*_patch
  # singleton methods minus the 3 NON_DISPATCHED ones and the dispatcher itself).
  # This test records which methods are actually called and verifies the set
  # matches, ensuring no patch was silently dropped or added.

  # The exact set that the original hardcoded list called (extracted from
  # the pre-refactor source at commit a625b84~1). Pinned here as a regression
  # guard: if a patch method is renamed or removed, this test catches it.
  ORIGINALLY_DISPATCHED = Ractor.make_shareable(%i[
    _install_rack_request_patch
    _install_inflector_patch
    _install_module_introspection_patch
    _install_parameter_encoding_patch
    _install_path_registry_patch
    _install_action_view_resolver_patch
    _install_action_view_partial_path_patch
    _install_action_view_field_type_patch
    _install_action_view_safe_join_patch
    _install_abstract_controller_patch
    _install_action_controller_controller_name_patch
    _install_flash_helpers_patch
    _install_csrf_reset_patch
    _install_active_support_error_reporter_patch
    _install_lookup_context_patch
    _install_i18n_patch
    _install_i18n_backend_patch
    _install_i18n_interpolation_patch
    _install_messages_serializer_patch
    _install_template_handlers_patch
    _install_execution_context_patch
    _install_request_parameter_parsers_patch
    _install_query_parser_patch
    _install_rack_utils_patch
    _install_log_subscriber_patch
    _install_local_cache_patch
    _install_reloader_patch
    _install_exception_wrapper_patch
    _install_action_dispatch_routing_patch
    _install_action_dispatch_mounted_helpers_patch
    _install_action_dispatch_http_url_patch
    _install_journey_routes_patch
    _install_warden_hooks_patch
    _install_warden_strategies_patch
    _install_devise_failure_app_patch
    _install_activerecord_connection_handler_patch
    _install_activerecord_configurations_patch
    _install_activerecord_db_config_handlers_patch
    _install_activerecord_query_transformers_patch
    _install_activerecord_module_attrs_patch
    _install_activerecord_deduplicable_patch
    _install_activerecord_pool_config_patch
    _install_activerecord_reaper_patch
    _install_arel_visitor_dispatch_cache_patch
    _install_arel_bind_block_patch
    _install_activerecord_quoting_cache_patch
    _install_activerecord_serialize_cast_value_patch
    _install_activerecord_delegation_patch
    _install_activerecord_primary_key_patch
    _install_activerecord_query_constraints_patch
    _install_activerecord_relation_delegate_cache_patch
    _install_active_model_attribute_method_patterns_patch
    _install_activerecord_model_classes_patch
    _install_active_model_naming_patch
    _install_active_record_core_patch
    _install_active_record_inheritance_patch
    _install_active_record_model_schema_patch
    _install_activerecord_model_schema_patch
    _install_openssl_digest_patch
    _install_caching_key_generator_patch
    _install_active_model_conversion_patch
    _install_activerecord_find_by_cache_patch
    _install_activerecord_migration_patch
    _install_activerecord_transaction_callbacks_patch
    _install_activerecord_query_logs_patch
    _install_kaminari_config_patch
    _install_propshaft_patch
    _install_devise_url_helpers_patch
    _install_devise_authenticatable_patch
    _install_polymorphic_routes_patch
    _install_orm_adapter_patch
    _install_warden_serializer_patch
    _install_json_encoding_patch
    _install_active_model_attribute_patch
    _install_hash_compute_if_absent_patch
  ].freeze)

  it "dispatches exactly the same set of patches as the original hardcoded list" do
    # Stub every _install_*_patch method to record its name when called,
    # without actually executing the patch logic (which requires Rails).
    called = []
    stubbed = []
    (RactorRailsShim.singleton_class.instance_methods(false) +
     RactorRailsShim.singleton_class.private_instance_methods(false))
      .map(&:to_sym)
      .select { |m| m.to_s.start_with?("_install_") && m.to_s.end_with?("_patch") }
      .reject { |m| m == :_install_all_framework_patches || NON_DISPATCHED.include?(m) }
      .each do |m|
      original = RactorRailsShim.method(m)
      stubbed << m
      RactorRailsShim.define_singleton_method(m) { called << m }
    end

    RactorRailsShim._install_all_framework_patches

    called_set = called.sort
    expected_set = ORIGINALLY_DISPATCHED.sort

    assert_equal expected_set, called_set,
                 "dispatched patches must match the original hardcoded list " \
                 "(missing: #{(expected_set - called_set).inspect}, " \
                 "extra: #{(called_set - expected_set).inspect})"
  ensure
    # Remove stubs so subsequent tests see the real methods. Re-require the
    # patch files to restore original definitions.
    stubbed&.each { |m| RactorRailsShim.singleton_class.remove_method(m) rescue nil }
    # Re-load patch files to restore real method definitions
    $LOADED_FEATURES
      .select { |f| f.include?("ractor_rails_shim/patches/") }
      .each { |f| $LOADED_FEATURES.delete(f) }
    require_relative "../lib/ractor_rails_shim/patches"
  end
end
