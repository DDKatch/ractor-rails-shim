# frozen_string_literal: true

# ConstantShareabilizer: the constant-shareability role extracted from the
# RactorRailsShim god module (Issue #13, Step 13.1; POODR §1 SRP).
#
# Owns the framework-agnostic machinery for making registered constants
# Ractor-shareable:
#   - make_shareable(path)        resolve + deep-freeze a constant by path
#   - make_value_shareable(val)   best-effort shareable replacement for a value
#   - safe_const_get(path)        no-raise constant path resolution
#   - split_const_path(path)      [owner, :name] split
#   - apply!                      run make_shareable across SHAREABLE_CONSTANTS
#   - shareable_constants         reader for the SHAREABLE_CONSTANTS registry
#   - install                     register the patch + apply (idempotent)
#
# `SHAREABLE_CONSTANTS` stays a constant on `RactorRailsShim` (per-concern
# files `concat` into it); this object reads it via the
# `shareable_constants_registry` seam (default = the facade constant). The
# `_swallow` debug funnel (`funnel`), `_register_patch` (`register_patch`),
# `_introspectable?` (`introspectable`), and the `NoOpLock` constant
# (`noop_lock_class`) are collaborators reached via the configure seam,
# defaulting to the facade lookups so existing call sites keep working
# (Issue #23, POODR §2 Dependencies). The `@applied` idempotency flag
# lives on `ConstantShareabilizer` itself (Issue #24, POODR §2 — own
# your own state).
#
# The RactorRailsShim singleton keeps facade methods that delegate, so the
# existing public/private API and naming_convention_spec / shim_spec /
# safe_const_get_spec / make_value_shareable_spec keep passing unchanged.

module RactorRailsShim
  module ConstantShareabilizer
    @funnel = nil
    @register_patch = nil
    @introspectable = nil
    @noop_lock_class = nil
    @shareable_constants_registry = nil

    # Inject the callable/class collaborators. `funnel` responds to
    # `call(label) { block }` (runs the block, rescues StandardError —
    # matches `_swallow`). `register_patch` responds to `call(name, ver)`.
    # `introspectable` responds to `call(val)` returning truthy/nil (matches
    # `_introspectable?`). `noop_lock_class` responds to `.new` (matches
    # `NoOpLock`). `shareable_constants_registry` is the array of constant
    # path strings. Passing `nil` for any (or calling
    # `reset_configuration`) restores the facade-lookup default.
    def self.configure(funnel: nil, register_patch: nil, introspectable: nil,
                       noop_lock_class: nil, shareable_constants_registry: nil)
      @funnel = funnel
      @register_patch = register_patch
      @introspectable = introspectable
      @noop_lock_class = noop_lock_class
      @shareable_constants_registry = shareable_constants_registry
    end

    # Restore the default (facade-lookup) collaborators. Test seam.
    def self.reset_configuration
    @applied = false
    @funnel = nil
      @register_patch = nil
      @introspectable = nil
      @noop_lock_class = nil
      @shareable_constants_registry = nil
    end

    # Has apply! fully resolved? Lives on ConstantShareabilizer (Issue #24 —
    # own your own state), NOT on the facade singleton.
    def self.applied?
      @applied
    end

    # Clear the applied flag. Test seam + reinstall seam.
    def self.reset_applied!
      @applied = false
    end

    def self.funnel
      @funnel || RactorRailsShim::Funnel.method(:swallow)
    end

    def self.register_patch
      @register_patch || RactorRailsShim.method(:_register_patch)
    end

    def self.introspectable
      @introspectable || RactorRailsShim.method(:_introspectable?)
    end

    def self.noop_lock_class
      @noop_lock_class || RactorRailsShim.singleton_class.const_get(:NoOpLock)
    end

    def self.shareable_constants_registry
      @shareable_constants_registry || RactorRailsShim::Registry.shareable_constants
    end

    # The registry of constant path strings whose values are made shareable
    # at boot. Lives on RactorRailsShim (per-concern files concat into it);
    # this reader delegates so call sites don't reach past the role object.
    def self.shareable_constants
      shareable_constants_registry
    end

    # Register the patch + apply it now if ActiveSupport is loaded. Called at
    # install time; if ActiveSupport isn't loaded yet, the constants don't
    # exist, so we re-run from patch_rails_module! (which fires once Rails —
    # and thus ActiveSupport — is defined). Guarded by
    # @applied so both paths are safe.
    def self.install
      register_patch.call(:shareable_constants, "8.1")
      return unless defined?(::ActiveSupport)

      apply!
    end

    # Run after Rails is fully booted (after Rails.application.initialize!)
    # and BEFORE spawning worker Ractors. Re-attempts to make every
    # registered constant shareable; constants that didn't exist at install
    # time (e.g. Rails::Railtie, loaded after `module Rails` opens) get
    # fixed here. Safe to call multiple times; already-shareable constants
    # are no-ops. MUST run in the main Ractor (const_set writes the
    # constant table). Public wrapper is `prepare_for_ractors!` on the
    # facade.
    def self.apply!
      return if @applied
      # Only set the done flag when every registered constant was made
      # shareable (or already was). If any returned false (constant doesn't
      # exist yet), leave the flag unset so a later call (from
      # make_app_shareable! or prepare_for_ractors!) retries the now-loadable
      # constants — otherwise workers hit IsolationError on the unshareable
      # values that were missed on the first pass.
      all_resolved = shareable_constants.map { |path| make_shareable!(path) }.all?
      @applied = true if all_resolved
    end

    # Resolve a constant path string to a value, and if it exists and is
    # not already shareable, replace it with its shareable (deep-frozen)
    # version. Returns true if the constant was made shareable (or already
    # was); false if it doesn't exist yet (caller may retry).
    def self.make_shareable!(const_path)
      owner, name = split_const_path(const_path)
      return false unless owner && name
      return true if owner.const_defined?(name, false) == false

      val = owner.const_get(name, false)
      return true if Ractor.shareable?(val)

      shareable = make_value_shareable(val)
      return true unless shareable

      # Deep-freeze and reassign. Ractor.make_shareable mutates `val` in
      # place (freezing it and its reachable objects) and returns it.
      # const_set warns "already initialized constant" because Rails'
      # environment_inquirer.rb defined the constant first. The reassign is
      # intentional (we're replacing the mutable value with its frozen
      # shareable twin), so silence that one warning.
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        owner.const_set(name, shareable)
      ensure
        $VERBOSE = verbose
      end
      true
    end

    # Best-effort shareable replacement for a constant value. Any object that
    # responds to `:synchronize` (the duck type for a Mutex-like lock — covers
    # Monitor, Mutex, and third-party lock classes alike) becomes a NoOpLock
    # (used as sentinel sentinels, e.g. PRIMARY_KEY_NOT_SET) can't be frozen
    # (BasicObject has no #freeze method) — replace with a frozen Symbol.
    # Everything else is deep-frozen via Ractor.make_shareable; if that
    # fails (e.g. a Proc, or a Concurrent::Map / TypeMap holding Procs —
    # both intrinsically unshareable and needing upstream Rails changes),
    # returns nil and the constant is left as-is (the worker will raise a
    # clear IsolationError on read).
    #
    # Uses the existing _introspectable? helper (make_shareable.rb) instead
    # of ad-hoc `rescue false` guards. BasicObject subclasses don't define
    # is_a?/respond_to? (Kernel not included); _introspectable? safely
    # detects this via a guarded respond_to?(:is_a?) check.
    def self.make_value_shareable(val)
      if introspectable.call(val) && val.respond_to?(:synchronize)
        Ractor.make_shareable(noop_lock_class.new)
      elsif !introspectable.call(val) || !val.respond_to?(:freeze)
        # Non-introspectable (BasicObject without is_a?) OR lacks #freeze
        # (BasicObject subclasses). Replace with a frozen Symbol sentinel —
        # it's compared with `equal?`, and a frozen Symbol is always
        # shareable.
        Ractor.make_shareable(:"__shim_unshareable_sentinel__")
      else
        funnel.call("make_value_shareable #{val.class}") { Ractor.make_shareable(val) }
      end
    end

    # Resolve a constant path string (e.g. "A::B::C") to its value, returning
    # nil if any segment isn't defined. When inherit is false, each segment
    # is looked up only in its parent's own constant table (const_get name,
    # false), matching the original no-inherit lookups in
    # _freeze_messages_constants!. Replaces dense rescue/& chains like:
    #   (Object.const_get(:A) rescue nil)&.const_get(:B, false) rescue nil
    def self.safe_const_get(path, inherit: true)
      path.split("::").inject(Object) { |ns, n| ns.const_get(n, inherit) } rescue nil
    end

    # Split "A::B::C" into [A::B (module), :C]. Returns [nil, nil] if the
    # parent isn't defined.
    def self.split_const_path(path)
      parts = path.split("::")
      return [Object, parts.first.to_sym] if parts.size == 1
      parent = safe_const_get(parts[0...-1].join("::"))
      return [nil, nil] unless parent
      [parent, parts.last.to_sym]
    end
  end
end