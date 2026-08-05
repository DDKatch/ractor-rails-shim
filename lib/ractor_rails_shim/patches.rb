# frozen_string_literal: true

# The core shim: reroute Rails' class-level instance variable accessors
# through Ractor-safe storage.
#
# Background: Rails stores global state in class ivars:
#
#   class Rails
#     class << self
#       attr_accessor :app_class, :cache, :logger
#       def application; @application ||= ...; end
#     end
#   end
#
# From a non-main Ractor these reads/writes raise Ractor::IsolationError:
#   "can not get unshareable values from instance variables of classes/modules
#    from non-main Ractors"
#
# The fix: store the values in ActiveSupport::IsolatedExecutionState, which
# is already Ractor-safe. It's thread-local storage (Thread.current[:key]),
# and each Ractor has its own threads, so each Ractor gets its own slot.
# Verified on Ruby 4.0.5: a non-main Ractor reads nil for a key the main
# Ractor set, sets its own value without error, and main's value is intact.
#
# IMPORTANT: all method redefinitions use module_eval with STRING, not
# define_method with a block. A block captures the defining Ractor's
# binding, and calling it from another Ractor raises:
#   "defined with an un-shareable Proc in a different Ractor"
# String eval produces methods with no captured binding, callable from any
# Ractor. Verified on Ruby 4.0.5.

begin
  require "active_support/isolated_execution_state"
rescue LoadError
  # ActiveSupport not installed — the fallback below provides the same API.
end
require_relative "storage"
require_relative "storage_strategy"
require_relative "fallback_ies"
require_relative "version_check"
require_relative "version_policy"
require_relative "run_mode"
require_relative "freezers"
require_relative "ar_model_walker"
require_relative "constant_shareabilizer"
require_relative "shareability_traversal"
require_relative "fallback_builder"
require_relative "worker_app"
require_relative "worker_app_factory"
require_relative "callback_capture"
require_relative "installer"
require_relative "logger_io_neutralizer"
require_relative "controller_collector"

# Naming convention for the patch methods on RactorRailsShim's singleton class:
#
#   install_<concern>      Public entry point called from `install` or
#                         `prepare_for_ractors!`. No underscore, no bang.
#                         Idempotent (guarded by its own @*_patched flag).
#                         Examples: install_class_attribute,
#                         install_shareable_constants, install_url_helpers_patch.
#
#   _install_<concern>_patch  Private worker that actually applies a patch.
#                            Leading underscore = private. No bang (the
#                            idempotency guard is on the public wrapper).
#                            Examples: _install_rack_request_patch,
#                            _install_activerecord_delegation_patch.
#
#   _freeze_*!            Private, mutates global state (freezes constants /
#                         class ivars). Bang signals the mutation.
#                         Examples: _freeze_shareable_class_ivars!,
#                         _freeze_active_record_class_ivars!.
#
#   _apply_*!             Private, mutates the install-done flag + constants.
#                         Examples: _apply_shareable_constants!.
#
#   <verb>_*!             Public lifecycle / build / snapshot verbs that mutate
#                         global state or freeze. Bang signals the mutation.
#                         Examples: prepare_for_ractors!, make_app_shareable!,
#                         snapshot_gem_paths!, worker_app!,
#                         fix_url_helpers_singleton_routes!.
#
#   _<helper>             Private, pure, or query helper. No bang.
#                         Examples: _swallow, _reassign_shareable_const,
#                         _make_value_shareable, _register_patch.
#
# The rule: leading underscore = private; bang = mutates receiver/global
# state (lifecycle verbs) or has a non-bang query sibling; public entry
# points are bang-less and idempotent.

# Per-concern patch files. Each reopens RactorRailsShim's singleton class
# to add its `_install_*` method(s). The order matters only for constants
# (core.rb defines the module skeleton + constants that others reference).
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
