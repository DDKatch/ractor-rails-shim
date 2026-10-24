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
      # Seed the ActiveStorage table prefix BEFORE installing framework
      # patches: the AR model-classes patch (_share_model_classes!) runs
      # load_schema on every concrete model, and with the prefix unseeded
      # ActiveStorage models compute table names like "attachments" — the
      # resulting PG::UndefinedTable attempts poison memoized attribute
      # state (@attribute_names / attribute_types) that later passes never
      # fully invalidate, so generate_ar_attribute_methods! then generates
      # attribute-method modules missing column writers (observed: workers
      # lose ActiveStorage::Attachment#name= → DelegationError on
      # Attachment.new). Seeding first closes that window.
      RactorRailsShim.__send__(:_seed_active_storage_prefix!) if RactorRailsShim.respond_to?(:_seed_active_storage_prefix!, true)
      # Multi-database support: capture each `connects_to` model's resolved
      # db config so workers can re-establish its pool (they cannot re-resolve
      # `connects_to` correctly once the class is lazily autoloaded).
      RactorRailsShim.__send__(:_capture_ar_connection_classes!) if RactorRailsShim.respond_to?(:_capture_ar_connection_classes!, true)
      # Pre-warm lazily-built message-verifier codecs ("active_record/
      # signed_id" etc.): workers read the frozen @codecs cache instead of
      # rebuilding via the NoOpProc'd rotation/secret-generator closures.
      # Runs AFTER the prefix seed, in the stable schema window. Guarded so
      # unit specs (which stub Rails without an application) still pass.
      if defined?(::Rails::Application) && ::Rails.application.is_a?(::Rails::Application)
        if RactorRailsShim::ShareabilityTraversal.respond_to?(:prewarm_message_verifier_codecs!, true)
          RactorRailsShim::ShareabilityTraversal.prewarm_message_verifier_codecs!(::Rails.application)
        end
      end
      PreSpawnSteps.install_framework_patches
      # Swap process-local cache stores (MemoryStore, NullStore) for a
      # shareable proxy BEFORE the app graph is frozen. Shares the frozen
      # store today raises FrozenError on the first cache call in every
      # Ractor (MemoryStore refreshes LRU order on reads). Solid Cache and
      # FileStore are left alone (shared by reference).
      RactorRailsShim::PerRactorCache.swap!
      RactorRailsShim.__send__(:_install_action_cable_worker_server_patch!) if RactorRailsShim.respond_to?(:_install_action_cable_worker_server_patch!, true)
      RactorRailsShim.__send__(:_install_solid_cable_configuration_patch!) if RactorRailsShim.respond_to?(:_install_solid_cable_configuration_patch!, true)
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
      compact_after_prepare!
    end

    # One boot-time GC.compact after the shareabilization passes. The
    # traversal + deep-freeze work churns the heap (free slots scattered
    # across pages); compacting once — while still in the main Ractor,
    # BEFORE any worker Ractor exists — hands every worker a tighter heap
    # for the process lifetime. This is a boot-time one-shot, NOT
    # GC.auto_compact: auto-compaction during live kino :ractor load is
    # known to hang (see the test app's bench/bench.rb compaction notes)
    # and is NOT enabled here.
    #
    # Opt-outs: RRAILS_SHIM_DISABLE_BOOT_COMPACT=1 (shim-specific) or
    # RUBY_GC_DISABLE_COMPACTION=1 (the interpreter-level switch — respect
    # it as a blanket "no compaction" directive).
    def self.compact_after_prepare!
      return false if ENV["RRAILS_SHIM_DISABLE_BOOT_COMPACT"]
      return false if ENV["RUBY_GC_DISABLE_COMPACTION"] == "1"
      GC.compact
      true
    end
  end
end
