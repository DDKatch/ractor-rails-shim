# frozen_string_literal: true

# Patch SimpleForm's global state for worker Ractors.
#
# Most config is `mattr_accessor` (the shim's mattr rewrite routes those),
# but three items sit outside that coverage:
#
#   1. `SimpleForm::FormBuilder.discovery_cache` — a class ivar on the
#      builder class (`@discovery_cache ||=`), WRITTEN during every render
#      when `cache_discovery` is on (production default) via
#      `find_mapping` (`discovery_cache[input_type] ||=`). First form
#      render in a worker: class-ivar read of a mutable Hash + lazy class
#      ivar WRITE → IsolationError. Fix: per-Ractor caches via
#      ::RactorRailsShim.storage (keyed per FormBuilder subclass); values are
#      input Classes (shareable), so the ractor-local cache works. Main
#      keeps its class-ivar cache.
#
#   2. `@@wrappers` — a RAW class-variable registry (NOT mattr_accessor, so
#      not auto-fixed) holding wrapper trees built by `SimpleForm.wrappers`
#      DSL blocks. `SimpleForm.wrapper(name)` is called per form render
#      (`@@wrappers[name.to_s] or raise WrapperNotFound`). Workers can
#      neither read the cvar (mutable Hash) nor the trees. Fix: capture the
#      registry into a shareable constant (deep-frozen wrapper trees — the
#      trees are read-only during rendering; the DSL runs entirely at
#      boot) and serve worker reads from the snapshot. Unshareable wrapper
#      content (a custom lambda inside a wrapper) keeps the capture nil:
#      workers raise the same WrapperNotFound-style error with a clear
#      shim message instead of an IsolationError.
#
#   3. The two Proc-valued mattrs — `@@label_text` and `@@field_error_proc`
#      (Procs defined in main; calling them from a worker raises even after
#      the mattr routing). Fix: worker readers return a FRESH lambda with
#      the same body, built in the calling Ractor (they close over nothing
#      but literals); main keeps the original accessors byte-for-byte.

module RactorRailsShim
  class << self
    def _install_simple_form_patch
      return if @simple_form_patched
      @simple_form_patched = true
      _register_patch :simple_form, "8.1"
      return unless defined?(::SimpleForm) && defined?(::SimpleForm::FormBuilder)

      _install_simple_form_discovery_cache
      _install_simple_form_wrappers_snapshot
      _install_simple_form_worker_safe_procs
    end

    private

    def _install_simple_form_discovery_cache
      ::SimpleForm::FormBuilder.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def discovery_cache
          if ::Ractor.main?
            @discovery_cache ||= {}
          else
            key = :"ractor_rails_shim_simple_form_discovery_\#{object_id}"
            ::RactorRailsShim.storage[key] ||= {}
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_simple_form_wrappers_snapshot
      shareable = nil
      if ::Ractor.main?
        wrappers = ::SimpleForm.class_variable_get(:@@wrappers) rescue nil
        if wrappers.is_a?(::Hash) && !wrappers.empty?
          shareable = _make_wrappers_shareable(wrappers)
        end
      end
      _reassign_shareable_const(:SIMPLE_FORM_WRAPPERS, shareable || {}.freeze)

      ::SimpleForm.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def wrapper(name)
          if ::Ractor.main?
            @@wrappers[name.to_s] or raise ::SimpleForm::WrapperNotFound, "Couldn't find wrapper with name \#{name}"
          else
            snapshot = ::RactorRailsShim::SIMPLE_FORM_WRAPPERS
            wrapper = snapshot && snapshot[name.to_s]
            unless wrapper
              raise ::SimpleForm::WrapperNotFound,
                "Couldn't find wrapper with name \#{name} in the worker-Ractor snapshot " \\
                "(register wrappers in an initializer; they must freeze cleanly)"
            end
            wrapper
          end
        end
      RUBY
    end

    # Plain deep-freeze first; on failure, the shim's proc/lock replacement
    # traversal; nil (capture stays empty) if the trees still can't freeze.
    def _make_wrappers_shareable(wrappers)
      ::Ractor.make_shareable(wrappers)
      wrappers
    rescue ::StandardError
      begin
        ::RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(wrappers)
        ::RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(wrappers)
        ::Ractor.make_shareable(wrappers)
        wrappers
      rescue ::StandardError
        nil
      end
    end

    def _install_simple_form_worker_safe_procs
      ::SimpleForm.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_label_text, :label_text
        def label_text
          if ::Ractor.main?
            _shim_original_label_text
          else
            ->(label, required, explicit_label) { "\#{required} \#{label}" }
          end
        end

        alias_method :_shim_original_field_error_proc, :field_error_proc
        def field_error_proc
          if ::Ractor.main?
            _shim_original_field_error_proc
          else
            proc { |html_tag, _instance_tag| html_tag }
          end
        end
      RUBY
    end
  end
end
