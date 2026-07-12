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
          ActiveSupport::IsolatedExecutionState[key] = value if Ractor.main?

          # Also store in CLASS_ATTR_VALUES so the reader can fall back to it
          # in the MAIN ractor on non-boot threads. IES is thread-local: Puma's
          # request threads have empty IES slots, so the reader returns nil
          # without this fallback. This is the bug that breaks normal (non-
          # Ractor) multi-threaded servers — the minimal --minimal app didn't
          # hit it because /up doesn't trigger LogSubscriber.log_levels.
          # CLASS_ATTR_VALUES is NOT shareable (values may be mutable); only
          # safe to read from the main ractor.
          RactorRailsShim::CLASS_ATTR_VALUES[key] = value

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
          RactorRailsShim::CLASS_ATTRIBUTES << [owner_label, namespaced_name, key, value]

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
          if RactorRailsShim.thread_mode?
            # Thread (Puma/Falcon) mode: route through a SHARED (process-wide)
            # store keyed by the actual class's object_id, walking ancestors
            # for copy-on-write fallback. This restores per-subclass isolation
            # (lost by the IES-routed variant) without thread-local IES, which
            # is empty on Puma's request threads.
            target.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{namespaced_name}
                self.ancestors.each do |anc|
                  v = RactorRailsShim::CLASS_ATTR_VALUES[:"ractor_rails_shim_class_attr_\#{anc.object_id}_#{namespaced_name}"]
                  return v unless v.nil?
                end
                #{namespaced_name.inspect} == :__callbacks ? {} : nil
              end

              def #{namespaced_name}=(new_value)
                RactorRailsShim::CLASS_ATTR_VALUES[:"ractor_rails_shim_class_attr_\#{self.object_id}_#{namespaced_name}"] = new_value
                new_value
              end
            RUBY

            # When owner is a module's singleton class, also override the
            # public reader `def #{name}` with the shared-store version.
            if owner.singleton_class? && owner.attached_object.is_a?(Module)
              owner.module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{name}
                  self.ancestors.each do |anc|
                    v = RactorRailsShim::CLASS_ATTR_VALUES[:"ractor_rails_shim_class_attr_\#{anc.object_id}_#{namespaced_name}"]
                    return v unless v.nil?
                  end
                  #{namespaced_name.inspect} == :__callbacks ? {} : nil
                end

                def #{name}=(new_value)
                  RactorRailsShim::CLASS_ATTR_VALUES[:"ractor_rails_shim_class_attr_\#{self.object_id}_#{namespaced_name}"] = new_value
                  new_value
                end
              RUBY
            end
           else
            target.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{namespaced_name}
                self.ancestors.each do |anc|
                  k = :"ractor_rails_shim_class_attr_\#{anc.object_id}_#{namespaced_name}"
                  v = ActiveSupport::IsolatedExecutionState[k]
                  return v unless v.nil?
                  fb = RactorRailsShim::SHAREABLE_FALLBACK[k]
                  return fb unless fb.nil?
                end
                RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] if Ractor.main?
              end

              def #{namespaced_name}=(new_value)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
                RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] = new_value if Ractor.main?
                new_value
              end
            RUBY

            # When owner is a module's singleton class, the original also
            # defines a public reader `def #{name} { value }` on owner directly
            # (block-based). Override it with the IES-routed version + fallback.
            if owner.singleton_class? && owner.attached_object.is_a?(Module)
              owner.module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{name}
                  self.ancestors.each do |anc|
                    k = :"ractor_rails_shim_class_attr_\#{anc.object_id}_#{namespaced_name}"
                    v = ActiveSupport::IsolatedExecutionState[k]
                    return v unless v.nil?
                    fb = RactorRailsShim::SHAREABLE_FALLBACK[k]
                    return fb unless fb.nil?
                  end
                  RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] if Ractor.main?
                end

                def #{name}=(new_value)
                  ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
                  RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] = new_value if Ractor.main?
                  new_value
                end
              RUBY
            end
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
  end
end
