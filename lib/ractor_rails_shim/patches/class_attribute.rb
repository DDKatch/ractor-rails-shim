# frozen_string_literal: true

# Rewrite ActiveSupport::ClassAttribute (used by `class_attribute`) so the
# reader/writer methods are defined via string eval instead of
# `define_method` with blocks. Blocks capture the defining Ractor's
# binding; calling them from a worker Ractor raises
# "defined with an un-shareable Proc in a different Ractor".
# `class_attribute` is used for Rails::Application#executor, #reloader,
# ActiveSupport::Reloader#executor/#check, and many framework globals —
# all read/written during app boot, which now runs in worker Ractors.
#
# Strategy: route the per-attribute storage (`__class_attr_<name>`) through
# IsolatedExecutionState, mirroring the mattr_accessor rewrite. Defaults
# are seeded once in the main Ractor at class_attribute-definition time
# (the original semantics). Worker Ractors get nil from the reader until
# they set their own value via the writer (which always works — the writer
# is string-eval'd, no captured binding). In practice workers boot their
# own app instance and the finisher sets executor/check/etc. during
# initialize!, so the default is only read as a fallback.

module RactorRailsShim
  # Frozen shared sentinel for the `__callbacks` class_attribute's
  # missing-slot default. Rails callers index the result
  # (`__callbacks[:process_action]`), so a missing slot must return an
  # empty Hash rather than nil. A single frozen constant avoids the
  # per-read `{}` allocation the original reader had. Defined on the
  # module (not the singleton class) so it's readable as
  # `RactorRailsShim::EMPTY_CALLBACKS_HASH` from the eval'd method
  # bodies. Made Ractor-shareable so worker Ractors can read it too.
  EMPTY_CALLBACKS_HASH = Ractor.make_shareable({}.freeze)

  class << self
    def install_class_attribute
      _register_patch :class_attribute, "8.1"
      return if @class_attr_patched
      @class_attr_patched = true
      if defined?(::ActiveSupport::ClassAttribute)
        patch_class_attribute!
      else
        # Defer until ActiveSupport::ClassAttribute loads. A TracePoint(:class)
        # fires when `module ClassAttribute` opens. One-shot.
        @ca_tp = TracePoint.new(:class) do |trace|
          if defined?(::ActiveSupport::ClassAttribute) && !@ca_patched
            @ca_tp.disable
            patch_class_attribute!
          end
        end
        @ca_tp.enable
      end
    end

    # The actual patch. Idempotent. Must run in the main Ractor.
    # `redefine` is a singleton method on ClassAttribute (defined in
    # `class << self`), so we prepend onto the singleton class.
    def patch_class_attribute!
      return if @ca_patched
      @ca_patched = true
      ::ActiveSupport::ClassAttribute.singleton_class.prepend(Module.new {
        # redefine is called once per attribute at class_attribute-definition
        # time (in the main Ractor). The original defines methods with blocks;
        # we replace with string-eval'd methods that route through IES so
        # they're callable from any Ractor. The default value is seeded into
        # the main Ractor's IES slot immediately (matching original semantics
        # where the reader returns the default until a subclass overrides).
        def redefine(owner, name, namespaced_name, value)
          key = :"ractor_rails_shim_class_attr_#{owner.object_id}_#{namespaced_name}"
          key_str = key.inspect

          # Seed the main Ractor's IES slot with the default. Only seed in
          # main — workers start nil and set their own value via the writer.
          RactorRailsShim.storage[key] = value if Ractor.main?

          # Also store in CLASS_ATTR_VALUES so the reader can fall back to it
          # in the MAIN ractor on non-boot threads. IES is thread-local: Puma's
          # request threads have empty IES slots, so the reader returns nil
          # without this fallback. This is the bug that breaks normal (non-
          # Ractor) multi-threaded servers — the minimal --minimal app didn't
          # hit it because /up doesn't trigger LogSubscriber.log_levels.
          # CLASS_ATTR_VALUES is NOT shareable (values may be mutable); only
          # safe to read from the main ractor.
          RactorRailsShim::Registry.class_attr_values[key] = value

          # Register so _build_shareable_fallback! can capture + make shareable
          # at prepare_for_ractors! time. owner.name may be nil for anonymous
          # classes (e.g. spec fixtures); use a stable label in that case.
          # The default value is stored too so the fallback builder can use it
          # when the live value can't be made shareable (e.g. __callbacks holds
          # self-capturing Procs — workers get the empty default, treating
          # boot-time callbacks as already-run, which is correct for a frozen
          # shared app).
          owner_label = owner.respond_to?(:name) ? owner.name : owner.class.name
          owner_label = owner_label || "anon_#{owner.class.name}_#{owner.object_id}"
          RactorRailsShim::Registry.class_attributes << [owner_label, namespaced_name, key, value]

          # Always define the namespaced reader/writer on owner's singleton
          # class via string eval (no captured binding). The class_attribute
          # macro itself also defines `def #{name}; #{namespaced_name}; end`
          # via class_eval (string-eval'd, safe) on the owner — that calls our
          # IES-routed namespaced reader/writer. We override BOTH the namespaced
          # and (when owner is a module's singleton) the public name.
          #
          # Worker-Ractor fallback: when the worker's own IES slot is empty
          # (which it is by default — the value lives in main's slot), fall
          # back to the frozen shareable table built at prepare_for_ractors!
          # time. This is read-only and shared across all workers; workers that
          # need their own mutable value call the writer, which writes their
          # IES slot and shadows the fallback.
          target = owner.singleton_class? ? owner : owner.singleton_class
          # Static missing-slot default: frozen shared Hash for __callbacks
          # (Rails indexes the result, so nil would NoMethodError), nil for
          # everything else. Decided once at method-definition time.
          missing_default = (name == :__callbacks) ? "RactorRailsShim::EMPTY_CALLBACKS_HASH" : "nil"
          # ONE heredoc for both modes — the selected strategy
          # (RactorRailsShim.storage_strategy, set once at install from
          # RunMode.thread?) decides the lookup/store backend. Collapses the
          # former two-mode `if thread_mode?` branch (Issue #15).
          target.module_eval RactorRailsShim._class_attr_methods(namespaced_name, key_str, missing_default),
                              __FILE__, __LINE__ + 1

          # When owner is a module's singleton class, the original also
          # defines a public reader `def #{name}` on owner directly. Override
          # it with the strategy-routed version.
          if owner.singleton_class? && owner.attached_object.is_a?(Module)
            owner.module_eval RactorRailsShim._class_attr_methods(name, key_str, missing_default),
                                __FILE__, __LINE__ + 1
          end

          # When owner IS a singleton class (e.g. called from class << self),
          # class_attribute's class_eval does `class << self` which opens a
          # nested singleton class. The public `def #{name}` ends up on
          # owner.singleton_class, which calls `#{namespaced_name}` — but
          # that method was only defined on `target` (= owner, the singleton
          # class), not on the nested level. Define it on owner.singleton_class
          # too so the nested `def #{name}` can resolve it.
          if owner.singleton_class?
            owner.singleton_class.module_eval RactorRailsShim._class_attr_methods(namespaced_name, key_str, missing_default),
                                               __FILE__, __LINE__ + 1
          end
        end

        # redefine_method is used by `redefine` internally and by other call
        # sites (rare). The class_attribute path goes through our `redefine`
        # above; keep the original block-based behavior for any other callers
        # so we don't break unrelated code.
        def redefine_method(owner, name, private: false, &block)
          super
        end
      })
    end

    # Build the reader/writer pair for one method name. ONE body for both
    # run modes — the selected `RactorRailsShim.storage_strategy` (set once
    # at install from `RunMode.thread?`) decides the lookup/store backend.
    # `method_name` is the def name (namespaced or public); `key_str` is the
    # inspected IES key Symbol literal (constant across both calls);
    # `missing_default` is the inlined missing-slot default expression
    # (string of Ruby source — only the Thread strategy consults it; the
    # Ractor strategy relies on IES + SHAREABLE_FALLBACK + CLASS_ATTR_VALUES).
    def _class_attr_methods(method_name, key_str, missing_default)
      <<~RUBY
        def #{method_name}
          RactorRailsShim.storage_strategy.lookup(self, #{key_str}, #{missing_default})
        end

        def #{method_name}=(new_value)
          RactorRailsShim.storage_strategy.store(self, #{key_str}, new_value)
          new_value
        end
      RUBY
    end
  end
end
