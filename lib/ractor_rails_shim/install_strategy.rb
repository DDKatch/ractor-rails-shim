# frozen_string_literal: true

# InstallStrategy: the composition objects that own the per-mode install
# bodies (Issue #26, POODR §5 Composition).
#
# StorageStrategy was split into ::Ractor/::Thread (storage_strategy.rb)
# — the POODR-correct shape. Installer.install did not get the same
# treatment: it kept an inline `if RactorRailsShim.thread_mode?` with
# two ~20-line bodies. This module extracts those bodies into strategy
# objects so the last `thread_mode?` branch is removed from Installer.
#
# The RactorRailsShim singleton keeps facade methods (install, installed?,
# _install_all_framework_patches) that delegate, so existing specs keep
# passing unchanged.

module RactorRailsShim
  module InstallStrategy
    # Full install for Ractor (Puma/Falcon in Ractor mode, Falcon): all
    # patches that route framework globals through per-Ractor IES.
    module Ractor
      def self.install
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
    end

    # Minimal install for thread (Puma/Falcon) servers: only the
    # class_attribute isolation fix + nil-safe callback replay. The
    # other patches route framework globals through per-Ractor IES,
    # which is empty on Puma's request threads and would break the app,
    # so they are skipped; the original Rails globals are thread-safe
    # and used as-is.
    module Thread
      def self.install
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
      end
    end
  end
end
