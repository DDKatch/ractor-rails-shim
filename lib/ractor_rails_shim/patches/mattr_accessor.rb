# frozen_string_literal: true

# Rewrite Module.mattr_accessor (and friends) so the accessor methods
# route through IsolatedExecutionState. Uses prepend + module_eval with
# strings to avoid cross-ractor binding issues.

module RactorRailsShim
  class << self
    def install_mattr_accessor
      _register_patch :mattr_accessor, "8.1"
      return if @mattr_patched
      @mattr_patched = true

      ::Module.prepend(Module.new {
        # The prepended module's body is evaluated in the main ractor at
        # prepend time; the methods it defines are callable from any ractor
        # because they're defined via string eval (no captured binding).
        # But mattr_accessor itself runs at app boot in the main ractor, and
        # the per-accessor redefinition must also use string eval.
        #
        # IMPORTANT: Rails' mattr_accessor/cattr_accessor stores values in
        # CLASS VARIABLES (@@sym), not class instance variables (@sym). The
        # default value is written via class_variable_set("@@sym", default).
        # Class variables are also subject to Ractor::IsolationError from
        # non-main ractors (verified on Ruby 4.0.5), so we route through IES
        # the same way — but the main-ractor fallback must read @@sym, and
        # the seed must run in the main ractor at define-time (via super).
        def mattr_accessor(*syms, instance_reader: true, instance_writer: true,
                           instance_accessor: true, default: nil, **kwargs, &block)
          shareable = kwargs[:shareable]
          mod_name = name

          # Compute the default value the same way Rails does, so we can
          # seed worker-ractor IES slots with it (workers can't read @@sym).
          # The block form is evaluated once here (in main ractor) like Rails.
          sym_default = block_given? && default.nil? ? yield : default

          super # define the methods via the original path (sets @@sym)

          syms.each do |sym|
            key = :"ractor_rails_shim_mattr_#{mod_name}_#{sym}"
            key_str = key.inspect
            cv = "@@#{sym}"
            cv_str = cv.inspect

            # Register so _build_shareable_fallback! can capture the main-ractor
            # value (read from @@sym) at prepare_for_ractors! time. The default
            # is stored too so the fallback builder can use it when the live
            # value can't be shared.
            RactorRailsShim._register_for_fallback(mod_name, sym, key, sym_default)

            # Store the default in a runtime registry (NOT inlined into the
            # eval'd method body — arbitrary objects like Logger have invalid
            # `.inspect` output). The reader looks it up by key. Also rebuilds
            # the shareable subset constant if the default is shareable.
            RactorRailsShim._seed_mattr_default(key, sym_default)

            # Redefine the class reader via string eval (no captured binding).
            # Class variables are only touched from the main ractor; worker
            # ractors fall back to SHAREABLE_FALLBACK (built from main's @@sym
            # at prepare_for_ractors! time) when their own IES slot is empty.
            # NOTE: we deliberately do NOT inline the default value here —
            # arbitrary objects (e.g. Logger) have invalid `.inspect` output.
            # The fallback builder captures the live value (which may equal
            # the default) at prepare time.
            singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{sym}
                v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                return v if ActiveSupport::IsolatedExecutionState.key?(#{key_str})

                if #{!!shareable}
                  if class_variable_defined?(#{cv_str})
                    class_variable_get(#{cv_str})
                  end
                elsif Ractor.main?
                  if class_variable_defined?(#{cv_str})
                    class_variable_get(#{cv_str})
                  else
                    nil
                  end
                else
                  # Worker: try the shareable fallback (built from main's @@sym
                  # at prepare_for_ractors! time). If empty, try the
                  # definition-time default (only the shareable subset — the
                  # full MATTR_DEFAULTS holds unshareable defaults like Logger
                  # which workers can't read via the constant).
                  fb = RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
                  return fb unless fb.nil?
                  RactorRailsShim::SHAREABLE_MATTR_DEFAULTS[#{key_str}]
                end
              end

              def #{sym}=(val)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                class_variable_set(#{cv_str}, val) if Ractor.main?
                val
              end
            RUBY

            # Instance readers/writers route through IES directly (NOT
            # self.class.#{sym}). Rails' original uses @@sym (a class variable
            # inherited by including classes); the shim routes through IES,
            # so the instance reader must also use IES. Using self.class.sym
            # would fail for mattr_accessor on Modules (e.g.
            # ActionView::Helpers::FormHelper#form_with_generates_ids):
            # self.class is the including class (ActionView::Base), which
            # doesn't have the module's singleton method.
            # Only redefine if instance_accessor is on (matches Rails).
            if instance_reader && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}
                  v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                  return v if ActiveSupport::IsolatedExecutionState.key?(#{key_str})
                  if Ractor.main?
                    self.class.class_variable_defined?(#{cv_str}) ? self.class.class_variable_get(#{cv_str}) : nil
                  else
                    RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
                  end
                end
              RUBY
            end
            if instance_writer && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}=(val)
                  ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                  self.class.class_variable_set(#{cv_str}, val) if Ractor.main? && self.class.class_variable_defined?(#{cv_str})
                  val
                end
              RUBY
            end
          end
        end

        # cattr_accessor is an alias for mattr_accessor in Rails; route it too.
        if method_defined?(:cattr_accessor, true)
          alias_method :_unshimmed_cattr_accessor, :cattr_accessor
          def cattr_accessor(*args, **kwargs, &block)
            mattr_accessor(*args, **kwargs, &block)
          end
        end
      })
    end

    # Store the definition-time default for a mattr accessor in the runtime
    # registry. If the default is shareable, also rebuild the
    # SHAREABLE_MATTR_DEFAULTS constant (frozen + made shareable) so worker
    # Ractors can read it before prepare_for_ractors! runs. The constant
    # reassignment goes through _reassign_shareable_const (centralized
    # $VERBOSE suppression).
    #
    # INVARIANT: this method MUST only be called pre-spawn (i.e. during boot
    # in the main Ractor, before worker Ractors are forked). The rebuild-
    # from-scratch pattern (`dup`, `freeze`, `make_shareable`, `const_set`)
    # reassigns the SHAREABLE_MATTR_DEFAULTS constant; any holder of a stale
    # reference (e.g. a worker that already read the constant) won't see the
    # update. The codebase is careful to call this only at mattr-definition
    # time (boot), but a future maintainer adding a post-spawn call would
    # silently break workers that cached the old constant. Don't.
    def _seed_mattr_default(key, default)
      MATTR_DEFAULTS[key] = default
      if default && Ractor.shareable?(default)
        h = SHAREABLE_MATTR_DEFAULTS.dup
        h[key] = default
        h.freeze
        Ractor.make_shareable(h)
        _reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, h)
      end
    end

    # Register a mattr accessor so _build_shareable_fallback! can capture +
    # make shareable the main-ractor value at prepare_for_ractors! time. The
    # default is stored too so the fallback builder can use it when the live
    # value can't be shared (e.g. __callbacks holds self-capturing Procs).
    def _register_for_fallback(mod_name, sym, key, default)
      CLASS_ATTRIBUTES << [mod_name, sym, key, default]
    end
  end
end
