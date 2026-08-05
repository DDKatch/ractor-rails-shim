# frozen_string_literal: true

# Installer: the orchestrator role extracted from the RactorRailsShim god
# module (Issue #13, Step 13.6; POODR §1 SRP).
#
# Owns the install entry point and the framework-patch dispatcher:
#   - install                          the top-level entry: version check,
#                                       run-mode resolve, branch by mode,
#                                       call the early-boot install_*
#                                       methods, set @installed
#   - installed?                       reader for the @installed flag
#   - dispatch_all_framework_patches  auto-discover + call every
#                                       _install_*_patch singleton method
#                                       on RactorRailsShim
#   - NON_DISPATCHED_FRAMEWORK_PATCHES  the exclusion list (patches called
#                                         from OTHER install paths, not the
#                                         dispatcher)
#
# The dispatcher's auto-discovery enumerates RactorRailsShim's singleton
# method table (where the _install_*_patch methods live, defined by the
# per-concern patch files that reopen `class << self`). This is the
# Open/Closed-correct mechanism already; only its home changes. The
# install_* methods it calls (install_mattr_accessor, install_class_attribute,
# ...) remain on the RactorRailsShim facade (defined by their patch files);
# the orchestrator reaches them through the facade.
#
# The `@installed` idempotency flag lives on `Installer` itself
# (Issue #24, POODR §2 — own your own state). The RactorRailsShim
# singleton keeps facade methods (install, installed?,
# _install_all_framework_patches) that delegate, so
# framework_patch_dispatch_spec, version_spec, and the integration spec
# keep passing unchanged.

module RactorRailsShim
  module Installer
    @installed = false
    # _install_*_patch methods called from OTHER install paths, not from the
    # dispatcher. They are installed by their parent install method (e.g.
    # _install_callbacks_nil_safe_patch and _install_notifications_notifier_
    # patch are called from patch_execution_wrapper!; _install_with_empty_
    # template_cache_patch is called from install via ActiveSupport.on_load).
    # Excluded from auto-discovery so they aren't double-installed.
    NON_DISPATCHED_FRAMEWORK_PATCHES = Ractor.make_shareable(%i[
      _install_callbacks_nil_safe_patch
      _install_notifications_notifier_patch
      _install_with_empty_template_cache_patch
    ].freeze)

    # Install all the patches. Safe to call multiple times (idempotent).
    # Delegates the early-boot install_* calls to the RactorRailsShim
    # facade (the methods live in their per-concern patch files).
    def self.install
      RactorRailsShim._check_version_support
      # Resolve the run mode (Ractor vs thread-server). Configuration is
      # owned by RunMode — explicit `thread_mode=` wins; otherwise we fall
      # back to ENV["SERVER"]. Lifted out of the old inline ENV read so
      # install is no longer non-deterministic on ambient ENV with no
      # visible config surface.
      RactorRailsShim::RunMode.resolve!

      # The storage strategy derives lazily from `RunMode.thread?` (see
      # `StorageStrategy#storage_strategy`), so no explicit assignment here.
      # `install_class_attribute` and the eval'd heredoc read
      # `RactorRailsShim.storage_strategy`, which returns Thread or Ractor
      # based on the resolved run mode. Tests that reset `RunMode` get the
      # correct strategy automatically (no stale stored value).

      if RactorRailsShim.thread_mode?
        # Minimal install for thread (Puma/Falcon) servers: only the
        # class_attribute isolation fix + nil-safe callback replay. The
        # other patches route framework globals through per-Ractor IES,
        # which is empty on Puma's request threads and would break the app,
        # so they are skipped; the original Rails globals are thread-safe
        # and used as-is.
        RactorRailsShim.install_class_attribute
        RactorRailsShim.install_execution_wrapper
        # Capture each controller's OWN declared before_action/after_action
        # filters at declaration time (during eager load) by intercepting
        # ActiveSupport::Callbacks.set_callback. This must be installed
        # BEFORE eager load so declarations are captured as they happen —
        # the class_attribute callback chain is corrupted by an eager-load
        # leak under Ruby 4.0.5 + Rails 8.1.3 + Devise, so reading
        # __callbacks later yields a wrong, unshareable chain. Install
        # requires active_support/callbacks to be loaded, so require it
        # first; install runs before the app's eager_load, so every
        # controller declaration is captured.
        require "active_support/callbacks" rescue nil
        RactorRailsShim._install_callback_declaration_capture!
      else
        RactorRailsShim.install_mattr_accessor
        RactorRailsShim.install_class_attribute
        RactorRailsShim.install_zeitwerk_registry
        RactorRailsShim.install_rubygems
        RactorRailsShim.install_rails_module
        RactorRailsShim.install_shareable_constants
        RactorRailsShim.install_execution_wrapper
        require "active_support/callbacks" rescue nil
        RactorRailsShim._install_callback_declaration_capture!
        # Patch ActionView::Base.with_empty_template_cache EARLY (before
        # eager load) so production's DetailsKey.view_context_class uses the
        # block-free version. The framework's original defines
        # compiled_method_container via define_method(&block) — an
        # un-shareable Proc that breaks worker Ractors. on_load fires as
        # soon as ActionView is required, well before the app's eager_load.
        ActiveSupport.on_load(:action_view) do
          RactorRailsShim._install_with_empty_template_cache_patch
        end
      end
      @installed = true
      true
    end

    def self.installed?
      @installed
    end

    # Auto-discover and call every _install_*_patch singleton method on
    # RactorRailsShim. Both `prepare_for_ractors!` (pre-worker boot) and
    # `make_app_shareable!` (post-boot, pre-freeze) call this. Each
    # _install_* is idempotent (guarded by its own @*_patched flag), so
    # calling the full set at either point is a no-op for already-applied
    # patches. The method table IS the registry — adding a new
    # _install_*_patch method to any patch file automatically includes it
    # here without editing this dispatcher (Open/Closed).
    def self.dispatch_all_framework_patches
      (RactorRailsShim.singleton_class.instance_methods(false) +
       RactorRailsShim.singleton_class.private_instance_methods(false))
        .map(&:to_sym)
        .select { |m| m.to_s.start_with?("_install_") && m.to_s.end_with?("_patch") }
        .reject { |m| m == :_install_all_framework_patches || NON_DISPATCHED_FRAMEWORK_PATCHES.include?(m) }
        .each { |m| RactorRailsShim.__send__(m) }
    end
  end
end