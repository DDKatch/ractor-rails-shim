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
# reassigns them via the configure seam, defaulting to the facade lookups
# (`class_attributes`, `class_attr_values`, `shareable_mattr_defaults`,
# `storage`, `safe_const_get`, `replace_unshareable_procs`,
# `replace_locks_and_concurrent_maps`, `reassign_shareable_const`). The
# traversal helpers (`_replace_unshareable_procs!`,
# `_replace_locks_and_concurrent_maps!`) live on ShareabilityTraversal
# (Issue #13, Step 13.2). This matches the Freezers::* and
# ConstantShareabilizer pattern (Issue #23, POODR §2 Dependencies).
#
# The `@built` idempotency flag lives on `FallbackBuilder` itself
# (Issue #24, POODR §2 — own your own state).
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# reassign_const_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module FallbackBuilder
    @built = false
    @safe_const_get = nil
    @replace_unshareable_procs = nil
    @replace_locks_and_concurrent_maps = nil
    @reassign_shareable_const = nil
    @class_attributes = nil
    @class_attr_values = nil
    @shareable_mattr_defaults = nil
    @storage = nil
    @value_lookup_chain = nil

    # Inject the callable + registry collaborators. The callables:
    # `safe_const_get(path)` → value|nil; `replace_unshareable_procs(val)`
    # and `replace_locks_and_concurrent_maps(val)` mutate val in place;
    # `reassign_shareable_const(sym, value)` reassigns the shareable
    # constant. The registries: `class_attributes` (CLASS_ATTRIBUTES
    # array), `class_attr_values` (CLASS_ATTR_VALUES store),
    # `shareable_mattr_defaults` (SHAREABLE_MATTR_DEFAULTS array),
    # `storage` (IES storage, hash-like: storage[ies_key]). The lookup
    # chain: `value_lookup_chain` (Array of lookup modules, each
    # responding to `.lookup(owner, attr_name, ies_key, **ctx) -> val|nil`).
    # Passing `nil` for any (or calling `reset_configuration`) restores
    # the facade-lookup default for that collaborator.
    def self.configure(safe_const_get: nil, replace_unshareable_procs: nil,
                       replace_locks_and_concurrent_maps: nil,
                       reassign_shareable_const: nil, class_attributes: nil,
                       class_attr_values: nil, shareable_mattr_defaults: nil,
                       storage: nil, value_lookup_chain: nil)
      @safe_const_get = safe_const_get
      @replace_unshareable_procs = replace_unshareable_procs
      @replace_locks_and_concurrent_maps = replace_locks_and_concurrent_maps
      @reassign_shareable_const = reassign_shareable_const
      @class_attributes = class_attributes
      @class_attr_values = class_attr_values
      @shareable_mattr_defaults = shareable_mattr_defaults
      @storage = storage
      @value_lookup_chain = value_lookup_chain
    end

    # Restore the default (facade-lookup) collaborators. Test seam.
    def self.reset_configuration
      @safe_const_get = nil
      @replace_unshareable_procs = nil
      @replace_locks_and_concurrent_maps = nil
      @reassign_shareable_const = nil
      @class_attributes = nil
      @class_attr_values = nil
      @shareable_mattr_defaults = nil
      @storage = nil
      @value_lookup_chain = nil
    end

    def self.safe_const_get
      @safe_const_get || RactorRailsShim::ConstantShareabilizer.method(:safe_const_get)
    end

    def self.replace_unshareable_procs
      @replace_unshareable_procs || RactorRailsShim::ShareabilityTraversal.method(:replace_unshareable_procs!)
    end

    def self.replace_locks_and_concurrent_maps
      @replace_locks_and_concurrent_maps || RactorRailsShim::ShareabilityTraversal.method(:replace_locks_and_concurrent_maps!)
    end

    def self.reassign_shareable_const
      @reassign_shareable_const || RactorRailsShim.method(:_reassign_shareable_const)
    end

    def self.class_attributes
      @class_attributes || RactorRailsShim::Registry.class_attributes
    end

    def self.class_attr_values
      @class_attr_values || RactorRailsShim::Registry.class_attr_values
    end

    def self.shareable_mattr_defaults
      @shareable_mattr_defaults || RactorRailsShim::Registry.shareable_mattr_defaults
    end

    def self.storage
      @storage || RactorRailsShim.storage
    end

    def self.value_lookup_chain
      @value_lookup_chain || ValueLookup::DEFAULT_CHAIN
    end

    # ValueLookup: Chain of Responsibility for resolving class_attribute /
    # mattr_accessor values during fallback build (Issue #40, POODR §5b).
    # Each link is a module responding to
    # `.lookup(owner_name, attr_name, ies_key, **ctx) -> val|nil`. The
    # chain is walked in order; the first non-nil value wins. The five
    # sequential `if val.nil? && ...` branches in `build!` become a loop
    # over the chain — adding a new lookup source is a one-line module
    # instead of a new `elsif`.
    module ValueLookup
      # IES slot — the primary source for class_attribute values.
      module Ies
        def self.lookup(_owner_name, _attr_name, ies_key, storage:, **)
          storage[ies_key]
        end
      end

      # CLASS_ATTR_VALUES — the main-Ractor store for values whose IES slot
      # was never written but whose definition-time DEFAULT was mutated
      # during boot (e.g. AbstractController::Base's `config`).
      module ClassAttrValues
        def self.lookup(_owner_name, _attr_name, ies_key, class_attr_values:, main: ::Ractor.main?, **)
          return nil unless main
          class_attr_values[ies_key]
        end
      end

      # @@class_variable — for mattr_accessor: the value may have been
      # written to @@sym after define-time (e.g. by an initializer).
      module Cvar
        def self.lookup(owner_name, attr_name, _ies_key, safe_const_get:, **)
          return nil unless owner_name && attr_name.is_a?(Symbol)
          owner_mod = safe_const_get.call(owner_name)
          return nil unless owner_mod && owner_mod.class_variable_defined?("@@#{attr_name}")
          owner_mod.class_variable_get("@@#{attr_name}")
        rescue StandardError
          nil
        end
      end

      # @instance_variable — for raw class ivars (PathRegistry, etc.):
      # read @<attr_name> in main.
      module Ivar
        def self.lookup(owner_name, attr_name, _ies_key, safe_const_get:, **)
          return nil unless owner_name && attr_name.is_a?(Symbol)
          owner_mod = safe_const_get.call(owner_name)
          return nil unless owner_mod && owner_mod.instance_variable_defined?("@#{attr_name}")
          owner_mod.instance_variable_get("@#{attr_name}")
        rescue StandardError
          nil
        end
      end

      # Rails module accessors — for owner_name == "Rails": the value may
      # live in the @ivar set by Rails' own writer or lazy-init'd by
      # Rails' own reader. Read via the actual accessor in main.
      module RailsSend
        def self.lookup(owner_name, attr_name, _ies_key, **)
          return nil unless owner_name == "Rails" && defined?(::Rails)
          ::Rails.public_send(attr_name) if ::Rails.respond_to?(attr_name, false)
        rescue StandardError
          nil
        end
      end

      # The default lookup chain, walked in order by build!. Frozen at
      # load time; the `configure` seam injects a custom chain for tests.
      DEFAULT_CHAIN = [
        Ies,
        ClassAttrValues,
        Cvar,
        Ivar,
        RailsSend,
      ].freeze
    end

    # Has build! run? Lives on FallbackBuilder (Issue #24 — own your
    # own state), NOT on the facade singleton.
    def self.built?
      @built
    end

    # Clear the built flag. Test seam + reinstall seam.
    def self.reset_built!
      @built = false
    end

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
    # @built on FallbackBuilder itself).
    def self.build!
      return nil if @built
      @built = true

      fallback = {}
      chain = value_lookup_chain
      lookup_ctx = {
        storage: storage,
        class_attr_values: class_attr_values,
        main: ::Ractor.main?,
        safe_const_get: safe_const_get,
      }
      class_attributes.each do |(owner_name, attr_name, ies_key, default_val)|
        # Skip the Rails logger — it's intrinsically unshareable (IO + Mutex +
        # mutable formatter) and workers build their own per-Ractor logger
        # via the patched reader. Trying to make it shareable would freeze the
        # IO, breaking logging in main too.
        next if owner_name == "Rails" && attr_name == :logger

        # Walk the ValueLookup chain to resolve the value. The first
        # non-nil result wins; if all links return nil, val stays nil.
        val = nil
        chain.each do |link|
          val = link.lookup(owner_name, attr_name, ies_key, **lookup_ctx)
          break unless val.nil?
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
      shareable_mattr_defaults.freeze
      Ractor.make_shareable(shareable_mattr_defaults)

      reassign_shareable_const.call(:SHAREABLE_FALLBACK, fallback)
      reassign_shareable_const.call(:SHAREABLE_MATTR_DEFAULTS, shareable_mattr_defaults)
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
        replace_unshareable_procs.call(val)
        replace_locks_and_concurrent_maps.call(val)
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
    # Uses the ShareableCopy dispatch table (Issue #40, POODR §5b).
    def self.shareable_copy(val)
      ShareableCopy.call(val)
    end

    # Dispatch table for shareable copies of mutable default containers.
    # Replaces the case/if type-switch in FallbackBuilder.shareable_copy and
    # GlobalConstantFreezer.call. Adding a new shareable-copy type is a
    # one-line table entry (Issue #40, POODR §5b).
    module ShareableCopy
      COPIERS = {
        Hash  => ->(v) { v.dup },
        Array => ->(v) { v.dup },
      }.freeze

      def self.call(val)
        copier = COPIERS.find { |klass, _| val.is_a?(klass) }&.last
        copier ? copier.call(val) : val
      end
    end
  end
end