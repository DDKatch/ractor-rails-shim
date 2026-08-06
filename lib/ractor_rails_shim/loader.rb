# frozen_string_literal: true

# Loader: the single require hub for ractor-rails-shim.
#
# POODR §1 SRP: this file has ONE job — require every component in
# dependency order. It owns no constants, no logic, no class/module
# definitions. Every other file in the gem defines exactly one concern.
#
# Dependency order (layered directory structure):
#   1. Foundation modules — foundation/ (no internal deps)
#   2. Role objects       — roles/ (depend on foundation)
#   3. Patch files        — patches/ (depend on role objects + foundation)

begin
  require "active_support/isolated_execution_state"
rescue LoadError
  # ActiveSupport not installed — the fallback below provides the same API.
end

# --- Foundation modules — foundation/ (no internal deps) ---
require_relative "version"
require_relative "foundation/funnel"
require_relative "foundation/registry"
require_relative "foundation/storage"
require_relative "foundation/ies_accessor"
require_relative "foundation/const_reassign"
require_relative "foundation/version_check"
require_relative "foundation/version_policy"
require_relative "foundation/run_mode"
require_relative "foundation/role_defaults"
require_relative "foundation/storage_strategy"

# --- Role objects — roles/ (depend on foundation) ---
require_relative "roles/ar_model_walker"
require_relative "roles/constant_shareabilizer"
require_relative "roles/shareability_traversal"
require_relative "roles/callback_capture"
require_relative "roles/fallback_builder"
require_relative "roles/pre_spawn_steps"
require_relative "roles/freezers"
require_relative "roles/worker_app"
require_relative "roles/worker_app_factory"
require_relative "roles/app_shareabilizer"
require_relative "roles/installer"
require_relative "roles/install_strategy"
require_relative "roles/logger_io_neutralizer"
require_relative "roles/lifecycle"
require_relative "roles/fallback_ies"
require_relative "roles/check"

# --- Patch files — patches/ (depend on role objects + foundation) ---
require_relative "patches/core"
require_relative "patches/callables"
require_relative "patches/hash_compute_if_absent"
require_relative "patches/make_shareable"
require_relative "patches/rails_module"
require_relative "patches/mattr_accessor"
require_relative "patches/class_attribute"
require_relative "patches/zeitwerk_registry"
require_relative "patches/route_helpers"
require_relative "patches/url_helpers"
require_relative "patches/execution_wrapper"
require_relative "patches/rack"
require_relative "patches/action_view"
require_relative "patches/action_controller"
require_relative "patches/action_dispatch"
require_relative "patches/polymorphic_routes"
require_relative "patches/active_support"
require_relative "patches/i18n"
require_relative "patches/warden"
require_relative "patches/active_model_attribute"
require_relative "patches/active_record_model_schema"
require_relative "patches/activerecord"
require_relative "patches/kaminari"
require_relative "patches/propshaft"
require_relative "patches/devise"
require_relative "patches/orm_adapter"
require_relative "patches/openssl"
require_relative "patches/rubygems"
