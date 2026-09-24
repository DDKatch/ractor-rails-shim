# frozen_string_literal: true

# Lifecycle: the pre-spawn orchestration extracted from patches/core.rb
# (POODR §1 SRP — "small objects in their own files").
#
# `prepare_for_ractors!` is the public entry point called after
# Rails.application.initialize! and BEFORE spawning worker Ractors.
# It sequences the shared pre-spawn steps (via PreSpawnSteps) and the
# unique steps (snapshot, url_helpers, freezers) that only
# prepare_for_ractors! needs.
#
# The RactorRailsShim singleton keeps a facade method that delegates
# here, so existing call sites keep working unchanged.

module RactorRailsShim
  module Lifecycle
    # Run after Rails.application.initialize! and BEFORE spawning
    # worker Ractors. Makes every registered constant shareable
    # (deep-freeze), freezes shareable class ivars, dispatches all
    # framework patches, snapshots gem paths, and warms caches.
    #
    # Idempotent; safe to call multiple times. Must run in the main
    # Ractor.
    def self.prepare_for_ractors!
      if RactorRailsShim::RunMode.thread?
        warn(
          "[ractor-rails-shim] prepare_for_ractors! skipped: thread mode is active " \
          "(RactorRailsShim.thread_mode = true). prepare_for_ractors! is Ractor-mode-only — " \
          "it deep-freezes live Rails objects (db configs, constants) and installs the full " \
          "per-Ractor patch set, which breaks thread servers (Puma/Falcon/Thin/Webrick). " \
          "Remove this call from your boot, or drop thread_mode to run in Ractor mode."
        )
        return false
      end
      PreSpawnSteps.apply_shareable_constants
      PreSpawnSteps.freeze_shareable_class_ivars
      PreSpawnSteps.install_framework_patches
      RactorRailsShim.__send__(:_seed_active_storage_prefix!) if RactorRailsShim.respond_to?(:_seed_active_storage_prefix!, true)
      RactorRailsShim.__send__(:_freeze_secure_random_alphabets!) if RactorRailsShim.respond_to?(:_freeze_secure_random_alphabets!, true)
      RactorRailsShim.snapshot_gem_paths!
      RactorRailsShim.snapshot_query_logs!
      RactorRailsShim.install_url_helpers_patch
      RactorRailsShim.fix_url_helpers_singleton_routes!
      Freezers::CacheWarmer.call
      Freezers::ClassIvarFreezer.call
      Freezers::GlobalClassIvarFreezer.call
      Freezers::GlobalConstantFreezer.call
      Freezers::MessagesConstantsFreezer.call
    end
  end
end
