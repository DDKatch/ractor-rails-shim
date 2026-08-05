# frozen_string_literal: true

# FallbackBuilder: the shareable-fallback builder role extracted from the
# RactorRailsShim god module (Issue #13, Step 13.3; POODR §1 SRP).
#
# Owns the framework-config shareable fallback that worker Ractors read when
# their own IES slot is empty:
#   - build!                scan CLASS_ATTRIBUTES → shareable fallback Hash
#   - try_make_shareable     best-effort shareable replacement for one value
#   - shareable_copy         fresh dup of a mutable default container
#
# `CLASS_ATTRIBUTES`, `SHAREABLE_MATTR_DEFAULTS`, `SHAREABLE_FALLBACK`, and
# `CLASS_ATTR_VALUES` stay constants on `RactorRailsShim` (shared registries
# written by the class_attribute/mattr patches); this object reads and
# reassigns them via the facade (`_reassign_shareable_const`,
# `_safe_const_get`). The traversal helpers
# (`_replace_unshareable_procs!`, `_replace_locks_and_concurrent_maps!`) are
# reached via the facade — they live on ShareabilityTraversal (Issue #13,
# Step 13.2). This matches the Freezers::* and ConstantShareabilizer pattern.
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# reassign_const_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module FallbackBuilder
    # Build the shareable fallback for every class_attribute / mattr_accessor
    # value the shim has rerouted. For each registered attribute we:
    #   1. Read the main-ractor value (from its IES slot, which `redefine`
    #      seeded at class_attribute-definition time).
    #   2. Make it shareable (deep-freeze + callable-replacement for any Procs
    #      it holds — same technique as make_app_shareable!, applied to the
    #      config sub-graph).
    #   3. Store under the IES key in a frozen Hash on RactorRailsShim, which
    #      is readable from every Ractor (it's a constant).
    # Workers' class_attribute readers fall back to this when their own IES
    # slot is nil. Must run in the main Ractor. Idempotent (guarded by
    # @fallback_built on the RactorRailsShim singleton).
    def self.build!
      return nil if RactorRailsShim.instance_variable_get(:@fallback_built)
      RactorRailsShim.instance_variable_set(:@fallback_built, true)

      fallback = {}
      RactorRailsShim::CLASS_ATTRIBUTES.each do |(owner_name, attr_name, ies_key, default_val)|
        # Skip the Rails logger — it's intrinsically unshareable (IO + Mutex +
        # mutable formatter) and workers build their own per-Ractor logger
        # via the patched reader. Trying to make it shareable would freeze the
        # IO, breaking logging in main too.
        next if owner_name == "Rails" && attr_name == :logger
        val = ActiveSupport::IsolatedExecutionState[ies_key]
        # For class_attribute values whose IES slot was never written but
        # whose definition-time DEFAULT was mutated in place during boot
        # (e.g. AbstractController::Base's `config`, whose default
        # ActiveSupport::OrderedOptions is filled with the real nested config
        # by railties), the live value lives in the main-Ractor
        # CLASS_ATTR_VALUES store, NOT in IES. Read it there so workers get
        # the real value instead of the empty definition-time default.
        if val.nil? && Ractor.main?
          val = RactorRailsShim::CLASS_ATTR_VALUES[ies_key]
        end
        # For mattr_accessor: the value may have been written to @@sym after
        # define-time (e.g. by an initializer). Read it from there if the IES
        # slot is nil (the seed only set the default; the live value may
        # differ).
        if val.nil? && owner_name && attr_name.is_a?(Symbol)
          begin
            owner_mod = RactorRailsShim._safe_const_get(owner_name)
            if owner_mod && owner_mod.class_variable_defined?("@@#{attr_name}")
              val = owner_mod.class_variable_get("@@#{attr_name}")
            end
          rescue StandardError => e
            # ignore — best-effort read
          end
        end
        # For raw class ivars (PathRegistry, etc.): read @<attr_name> in main.
        if val.nil? && owner_name && attr_name.is_a?(Symbol)
          begin
            owner_mod = RactorRailsShim._safe_const_get(owner_name)
            if owner_mod && owner_mod.instance_variable_defined?("@#{attr_name}")
              val = owner_mod.instance_variable_get("@#{attr_name}")
            end
          rescue StandardError => e
            # ignore — best-effort read
          end
        end
        # For the Rails module accessors (owner_name == "Rails"): the value
        # may live in the @ivar (set by Rails' own writer via super, or
        # lazy-init'd by Rails' own reader) rather than in IES. Read it via
        # the actual accessor in main, which materializes the lazy-init value.
        if val.nil? && owner_name == "Rails" && defined?(::Rails)
          begin
            val = ::Rails.public_send(attr_name) if ::Rails.respond_to?(attr_name, false)
          rescue StandardError => e
            # ignore — best-effort read
          end
        end

        shareable_val = nil
        # Try the live value first.
        if !val.nil?
          shareable_val = try_make_shareable(val, owner_name, attr_name)
        end
        # If the live value couldn't be shared (e.g. __callbacks holds
        # self-capturing Procs), fall back to the definition-time default.
        # For a frozen shared app this is correct: boot-time callbacks
        # already ran in main; workers treat them as already-run
        # (empty/no-op). The default is dup'd if it's a mutable container
        # (Hash/Array) so each entry in the fallback is an independent
        # shareable copy.
        if shareable_val.nil? && !default_val.nil?
          shareable_val = try_make_shareable(shareable_copy(default_val), owner_name, attr_name, default: true)
        end

        fallback[ies_key] = shareable_val if shareable_val
      end
      fallback.freeze
      Ractor.make_shareable(fallback)

      # Make the shareable mattr-defaults subset shareable too (workers
      # read it via the constant). Frozen + reassigned via the centralized
      # helper.
      RactorRailsShim::SHAREABLE_MATTR_DEFAULTS.freeze
      Ractor.make_shareable(RactorRailsShim::SHAREABLE_MATTR_DEFAULTS)

      RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, fallback)
      RactorRailsShim._reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, RactorRailsShim::SHAREABLE_MATTR_DEFAULTS)
      fallback
    end

    # Best-effort attempt to make `val` shareable (callable-replacement for
    # Procs + lock-replacement + make_shareable). Returns the shareable val,
    # or nil if it can't be made shareable. On failure, emits a warning
    # (unless `default:` — defaults are expected to sometimes be unshareable,
    # so we skip the noise).
    def self.try_make_shareable(val, owner_name, attr_name, default: false)
      # __callbacks and validators hold callback chains / validator
      # instances with self-capturing Procs that can NEVER be made
      # shareable. This is expected: workers correctly treat callbacks as
      # already-run (the nil-safe run_callbacks patch yields the block
      # directly). Skip the attempt entirely — don't waste cycles traversing
      # the graph, and don't emit warnings for known-expected failures.
      attr_sym = attr_name.to_s
      return nil if attr_sym.end_with?("__callbacks") ||
                    attr_sym.end_with?("__validators") ||
                    attr_sym.end_with?("default_connection_handler")

      begin
        RactorRailsShim._replace_unshareable_procs!(val)
        RactorRailsShim._replace_locks_and_concurrent_maps!(val)
        Ractor.make_shareable(val)
        val
      rescue StandardError => e
        unless default
          warn "ractor-rails-shim: could not make attribute " \
               "#{owner_name}##{attr_name} shareable (#{e.class}: #{e.message[0,80]}); workers will fall back to default or nil"
        end
        nil
      end
    end

    # Return a fresh copy of a mutable default container (Hash/Array) so the
    # fallback entry is independent. Frozen/shareable defaults pass through.
    def self.shareable_copy(val)
      case val
      when Hash then val.dup
      when Array then val.dup
      else val
      end
    end
  end
end