# frozen_string_literal: true

# CallbackCapture: the callback-declaration capture role extracted from
# the RactorRailsShim god module (Issue #13, Step 13.5; POODR §1 SRP).
#
# Owns the machinery that captures each controller's OWN declared
# `process_action` symbolic filters (before_action / after_action) during
# eager load, so worker Ractors can replay them:
#   - install_callback_declaration_capture!  alias set_callback, intercept
#                                            symbolic declarations
#   - record_declared_callback(klass_id, kind, filter, only, except)
#   - freeze_declared_callbacks!              build the shareable constant
#   - read_action_filter_constraints(af)      read @conditional_key/@actions
#                                              off an ActionFilter
#   - read_ivar_or_warn(obj, ivar, label)     version-gated ivar read
#
# The interceptor (string-eval'd, no captured binding) calls
# `RactorRailsShim._read_action_filter_constraints` and
# `RactorRailsShim._record_declared_callback` via the facade — those names
# are load-bearing (the eval'd method body resolves them at call time on
# whatever Ractor runs it, and the facade delegates here). The @declared_
# callbacks table and @callback_capture_installed flag live on the
# RactorRailsShim singleton (the interceptor writes @declared_callbacks
# directly; keeping it on the singleton avoids changing the eval'd method
# body). The SHAREABLE_DECLARED_CALLBACKS constant lives on RactorRailsShim.
#
# The three callable collaborators — `_swallow` (funnel),
# `_reassign_shareable_const`, and `_register_patch` — are reached via the
# `funnel` / `reassign_shareable_const` / `register_patch` seams. The
# defaults are the facade lookups (`RactorRailsShim.method(:_swallow)`,
# `._reassign_shareable_const`, `._register_patch`) so existing call sites
# keep working; `configure(funnel:, reassign_shareable_const:, register_
# patch:)` injects different collaborators so the role is independently
# constructible and specable without the `RactorRailsShim` god module
# loaded (Issue #23, POODR §2 Dependencies). The @declared_callbacks table
# and @callback_capture_installed flag stay on the facade singleton here —
# Issue #24 moves them onto this role.
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# debug_funnel_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module CallbackCapture
    @funnel = nil
    @reassign_shareable_const = nil
    @register_patch = nil

    # Inject the callable collaborators. `funnel` responds to
    # `call(label) { block }` (runs the block, rescues StandardError —
    # matches `_swallow`). `reassign_shareable_const` responds to
    # `call(sym, value)` (reassigns the shareable constant). `register_
    # patch` responds to `call(name, version)` (records the patch tag).
    # Passing `nil` for any (or calling `reset_configuration`) restores
    # the facade-lookup default for that collaborator.
    def self.configure(funnel: nil, reassign_shareable_const: nil, register_patch: nil)
      @funnel = funnel
      @reassign_shareable_const = reassign_shareable_const
      @register_patch = register_patch
    end

    # Restore the default (facade-lookup) collaborators. Test seam.
    def self.reset_configuration
      @funnel = nil
      @reassign_shareable_const = nil
      @register_patch = nil
    end

    # The active funnel: the injected one if configured, else the
    # facade lookup (`RactorRailsShim.method(:_swallow)`).
    def self.funnel
      @funnel || RactorRailsShim.method(:_swallow)
    end

    # The active reassign callable: the injected one if configured, else
    # the facade lookup (`RactorRailsShim.method(:_reassign_shareable_const)`).
    def self.reassign_shareable_const
      @reassign_shareable_const || RactorRailsShim.method(:_reassign_shareable_const)
    end

    # The active register_patch callable: the injected one if configured,
    # else the facade lookup (`RactorRailsShim.method(:_register_patch)`).
    def self.register_patch
      @register_patch || RactorRailsShim.method(:_register_patch)
    end

    # Freeze (make Ractor-shareable) the captured declared-callbacks table
    # so worker Ractors can read it via the SHAREABLE_DECLARED_CALLBACKS
    # constant. Deep-freeze (make shareable) so workers can read the
    # constant. Entries are Hashes of Symbols/booleans/nil/Arrays — all
    # natively shareable. A non-frozen constant raises
    # Ractor::IsolationError when a worker reads it.
    def self.freeze_declared_callbacks!
      table = (RactorRailsShim.instance_variable_get(:@declared_callbacks) || {})
      funnel.call("freeze declared callbacks") do
        Ractor.make_shareable(table)
        reassign_shareable_const.call(:SHAREABLE_DECLARED_CALLBACKS, table)
      end
    end

    # Record a single declared symbolic filter. Called from the
    # set_callback interceptor during eager load (main Ractor only).
    def self.record_declared_callback(klass_id, kind, filter, only, except)
      RactorRailsShim.instance_variable_set(:@declared_callbacks, {}) unless RactorRailsShim.instance_variable_defined?(:@declared_callbacks)
      table = RactorRailsShim.instance_variable_get(:@declared_callbacks)
      (table[klass_id] ||= []) << {
        kind: kind,
        filter: filter,
        only: (only.freeze if only),
        except: (except.freeze if except)
      }
    end

    # Install an interceptor on ActiveSupport::Callbacks.set_callback that
    # records, per declaring class, every symbolic `:process_action` filter
    # it declares. This must run BEFORE eager load (so declarations are
    # captured as they happen) — install wires it via the
    # ActiveSupport.on_load(:active_support) hook in `install`.
    def self.install_callback_declaration_capture!
      return if RactorRailsShim.instance_variable_get(:@callback_capture_installed)
      register_patch.call(:action_filter_introspection, "8.1")
      RactorRailsShim.instance_variable_set(:@callback_capture_installed, true)
      # ActiveSupport::Callbacks may not be loaded yet at
      # on_load(:active_support) time (it's required lazily). Require it so
      # the ClassMethods module with set_callback exists before we alias it.
      require "active_support/callbacks" rescue nil
      mod = (defined?(::ActiveSupport::Callbacks) &&
             ::ActiveSupport::Callbacks.const_defined?(:ClassMethods)) ?
            ::ActiveSupport::Callbacks::ClassMethods : nil
      return unless mod && mod.method_defined?(:set_callback)
      # Alias the original `set_callback` exactly once. The @callback_
      # capture_installed guard above short-circuits a second install, but
      # specs clear that flag to test the install path in isolation; without
      # this `unless`, the second alias overwrites `_rrs_orig_set_callback`
      # with the *interceptor* (which is now `set_callback`), so any later
      # `set_callback` call recurses infinitely through the interceptor.
      mod.alias_method(:_rrs_orig_set_callback, :set_callback) unless mod.method_defined?(:_rrs_orig_set_callback)
      mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def set_callback(name, *filters, &block)
          if name == :process_action && filters.length >= 2 && filters[0].is_a?(Symbol)
            kind = filters[0]
            filter = filters[1]
            if filter.is_a?(Symbol) &&
               self.is_a?(::Class) &&
               self.ancestors.include?(::AbstractController::Base)
              # Rails converts `only:`/`except:` into an ActionFilter object
              # stored in the callback's `:if`/`:unless` options (NOT a bare
              # `:only` key). Read the constraint back from the ActionFilter's
              # @conditional_key (:only/:except) and @actions (a Set of action
              # name Strings) via the extracted, version-gated helper.
              opts = filters.find { |f| f.is_a?(Hash) }
              only = nil
              except = nil
              if opts
                [opts[:if], opts[:unless]].each do |arr|
                  next unless arr.is_a?(Array)
                  arr.each do |af|
                    ck, acts = ::RactorRailsShim._read_action_filter_constraints(af)
                    next unless ck && acts
                    only = acts if ck == :only
                    except = acts if ck == :except
                  end
                end
              end
              ::RactorRailsShim._record_declared_callback(
                self.object_id, kind, filter, only, except)
            end
          end
          _rrs_orig_set_callback(name, *filters, &block)
        end
      RUBY
      RactorRailsShim.instance_variable_set(:@callback_capture_installed, true)
    end

    # Read @conditional_key and @actions off an ActionFilter instance (Rails
    # internal ivars). Returns [conditional_key, actions_as_symbols]. On a
    # Rails version where the ivars are renamed/absent, returns [nil, nil].
    # A missing ivar means callbacks run for actions they shouldn't
    # (security-relevant). instance_variable_get returns nil for a missing
    # ivar without raising, so we check instance_variable_defined? and emit
    # a labeled warning via _swallow when debug=true so a silent Rails rename
    # is visible during diagnosis.
    def self.read_action_filter_constraints(af)
      ck = read_ivar_or_warn(af, :@conditional_key, "action filter constraints")
      acts = read_ivar_or_warn(af, :@actions, "action filter constraints")
      acts = acts.to_a.map(&:to_sym) if acts && acts.respond_to?(:to_a)
      [ck, acts]
    end

    # Read an ivar; if it's undefined, behavior is gated by VersionPolicy:
    #   :strict — raise UnsupportedVersionError (a missing ivar means
    #             callbacks run for actions they shouldn't; failing loud
    #             pins the security-relevant failure mode instead of
    #             silently mis-routing callbacks)
    #   :warn   — emit a labeled warning via _swallow when debug? so a silent
    #             Rails internal rename surfaces during diagnosis
    #   :off    — silent nil
    # Returns the ivar value or nil (under :warn/:off).
    def self.read_ivar_or_warn(obj, ivar, label)
      return obj.instance_variable_get(ivar) if obj.instance_variable_defined?(ivar)
      case RactorRailsShim::VersionPolicy.policy
      when :strict
        raise RactorRailsShim::VersionPolicy::UnsupportedVersionError,
              "#{label}: missing ivar #{ivar} on #{obj.class}"
      when :off
        nil
      else
        funnel.call(label) { warn "[ractor_rails_shim] #{label}: missing ivar #{ivar} on #{obj.class}" } if RactorRailsShim.debug?
        nil
      end
    end
  end
end