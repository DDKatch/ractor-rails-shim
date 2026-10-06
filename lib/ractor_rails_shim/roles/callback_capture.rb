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
# `RactorRailsShim::CallbackCapture.read_action_filter_constraints` and
# `RactorRailsShim::CallbackCapture.record_declared_callback` directly —
# those names are load-bearing (the eval'd method body resolves them at
# call time on whatever Ractor runs it). Issue #36a (Round 4): the
# @declared_callbacks table now lives on CallbackCapture itself (a class
# instance variable), NOT on the RactorRailsShim facade singleton — the
# role owns its own state. The SHAREABLE_DECLARED_CALLBACKS constant
# lives on RactorRailsShim (reassigned via _reassign_shareable_const).
#
# The three callable collaborators — `_swallow` (funnel),
# `_reassign_shareable_const`, and `_register_patch` — are reached via the
# `funnel` / `reassign_shareable_const` / `register_patch` seams. The
# defaults are the facade lookups (`RactorRailsShim::Funnel.method(:swallow)`,
# `._reassign_shareable_const`, `._register_patch`) so existing call sites
# keep working; `configure(funnel:, reassign_shareable_const:, register_
# patch:)` injects different collaborators so the role is independently
# constructible and specable without the `RactorRailsShim` god module
# loaded (Issue #23, POODR §2 Dependencies). Issue #36a (Round 4): the
# @declared_callbacks table lives on CallbackCapture itself (the role
# owns its state); the `@installed` idempotency flag also lives on
# `CallbackCapture` (Issue #24, POODR §2 — own your own state).
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# debug_funnel_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module CallbackCapture
    extend RoleDefaults

    @installed = false
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

    # Has install_callback_declaration_capture! run? Lives on
    # CallbackCapture (Issue #24 — own your own state), NOT on the
    # facade singleton.
    def self.installed?
      @installed
    end

    # Clear the installed flag. Test seam + reinstall seam.
    def self.reset_installed!
      @installed = false
    end

    # The active funnel: the injected one if configured, else the
    # facade lookup (`RactorRailsShim::Funnel.method(:swallow)`).
    def self.funnel
      @funnel || default_funnel
    end

    # The active reassign callable: the injected one if configured, else
    # the facade lookup (`RactorRailsShim.method(:_reassign_shareable_const)`).
    def self.reassign_shareable_const
      @reassign_shareable_const || default_reassign_shareable_const
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
      table = (@declared_callbacks || {})
      funnel.call("freeze declared callbacks") do
        Ractor.make_shareable(table)
        reassign_shareable_const.call(:SHAREABLE_DECLARED_CALLBACKS, table)
      end
    end

    # Record a single declared symbolic filter. Called from the
    # set_callback interceptor during eager load (main Ractor only). `chain_kind`
    # is the ActiveSupport::Callbacks chain name (:process_action, :save,
    # :create, :destroy, …); `phase` is :before / :after / :around. Storing chain_kind is
    # what generalizes replay beyond controllers to model lifecycle callbacks.
    # `on` / `except_on` are validation-context gates (Symbols or frozen
    # Arrays thereof, or nil) captured from Rails' `on:` / `except_on:`
    # options — Rails compiles those into unshareable Proc if:/unless:
    # conditions, so the transport gates on `validation_context` instead.
    def self.record_declared_callback(klass_id, chain_kind, phase, filter, only, except, if_cond = nil, unless_cond = nil, on = nil, except_on = nil)
      @declared_callbacks = {} unless defined?(@declared_callbacks)
      table = @declared_callbacks
      (table[klass_id] ||= []) << {
        chain_kind: chain_kind,
        phase: phase,
        filter: filter,
        only: (only.freeze if only),
        except: (except.freeze if except),
        if_cond: (if_cond.freeze if if_cond),
        unless_cond: (unless_cond.freeze if unless_cond),
        on: (on.freeze if on),
        except_on: (except_on.freeze if except_on)
      }
    end

    # Record a single declared VALIDATOR-object filter (an
    # ActiveModel::Validator instance registered by `validates` /
    # `validates_with` / `validates_associated`). `descriptor` is the frozen
    # shareable Hash built by build_validator_descriptor:
    #   { validator: "ActiveRecord::Validations::PresenceValidator",
    #     attributes: [:body] | nil, options: {…} | nil }
    # The transport rebuilds a fresh validator from the descriptor in the
    # worker and calls .validate(record) — this is what makes worker-side
    # `valid?` run real validations (row 1).
    def self.record_declared_validator_callback(klass_id, chain_kind, phase, descriptor, if_cond = nil, unless_cond = nil, on = nil, except_on = nil)
      @declared_callbacks = {} unless defined?(@declared_callbacks)
      table = @declared_callbacks
      (table[klass_id] ||= []) << {
        chain_kind: chain_kind,
        phase: phase,
        filter: descriptor[:validator],
        validator_attributes: descriptor[:attributes],
        validator_options: descriptor[:options],
        only: nil,
        except: nil,
        if_cond: (if_cond.freeze if if_cond),
        unless_cond: (unless_cond.freeze if unless_cond),
        on: (on.freeze if on),
        except_on: (except_on.freeze if except_on)
      }
    end

    # Decode if:/unless:/on:/except_on: conditions from a set_callback
    # options Hash into shareable values:
    #   [if_cond, unless_cond, on, except_on, all_resolvable]
    # Symbol conditions pass through as Symbols (the transport calls them on
    # the context). `on:` / `except_on:` are captured as Symbols or frozen
    # Arrays of Symbols — Rails compiles them into Proc conditions
    # (predicate_for_validation_context / the except_on lambda), which cannot
    # cross the Ractor wall, so the transport gates on the record's
    # `validation_context` instead; a Proc is considered RESOLVED only when
    # the :on / :except_on key that generated it is present in the options.
    # Any other Proc is unresolvable: `all_resolvable` comes back false and
    # the caller SKIPS the capture — the callback never replays in workers
    # (fail-safe: never over-runs; mirrors the transport's skip semantics for
    # unshareable Proc-defined methods).
    def self.decode_callback_conditions(opts)
      return [nil, nil, nil, nil, true] unless opts.is_a?(::Hash)
      if_cond = opts[:if].is_a?(::Symbol) ? opts[:if] : nil
      unless_cond = opts[:unless].is_a?(::Symbol) ? opts[:unless] : nil
      on = normalize_context_keys(opts[:on]) if opts.key?(:on)
      except_on = normalize_context_keys(opts[:except_on]) if opts.key?(:except_on)
      # An element is resolvable when:
      #   - it is a Symbol (captured as if_cond/unless_cond, called on the
      #     context by the transport), or
      #   - it is not a Proc at all (e.g. Rails' ActionFilter constraint
      #     objects compiled from only:/except: — handled by
      #     read_action_filter_constraints into the entry's only/except), or
      #   - it is a Proc that Rails GENERATED from on:/except_on: (captured
      #     as the shareable context keys; the transport gates on
      #     validation_context). Any other Proc is unresolvable.
      all_resolvable = condition_list(opts[:if]).all? do |c|
        c.is_a?(::Symbol) || !c.is_a?(::Proc) || opts.key?(:on)
      end &&
        condition_list(opts[:unless]).all? do |c|
          c.is_a?(::Symbol) || !c.is_a?(::Proc) || opts.key?(:except_on)
        end
      [if_cond, unless_cond, on, except_on, all_resolvable]
    end

    # A condition value as a flat list: a bare Symbol/Proc wraps into an
    # Array, an Array passes through, nil is empty.
    def self.condition_list(value)
      if value.is_a?(::Array) then value
      elsif value.nil? then []
      else [value]
      end
    end

    # Normalize an `on:` / `except_on:` value (:create, [:create, :update]) to
    # a frozen Symbol / frozen Array of Symbols; non-Symbol values → nil
    # (uncapturable — the transport then treats the gate as absent, matching
    # Rails' unconditional default).
    def self.normalize_context_keys(value)
      if value.is_a?(::Symbol)
        value
      elsif value.is_a?(::Array) && value.all?(::Symbol)
        value.map(&:to_sym).freeze
      end
    end

    # Build a shareable descriptor for a validator-object callback filter.
    # Returns a frozen Hash or nil when the validator's options are not
    # shareable (e.g. a custom validator capturing Procs) — the caller then
    # skips the capture so the validator never over-runs in workers.
    # Reconstruction contract: EachValidator#initialize deletes :attributes
    # from the options Hash it receives and stores the rest; plain Validators
    # receive the options Hash as-is. The descriptor mirrors both shapes:
    # attributes (from validator#attributes, nil for plain Validators) is
    # merged back into options by the transport before Klass.new. The
    # DECLARING class is merged back too when the set_callback options carry
    # it (validates_with sets options[:class] = self; Validator#initialize
    # strips :class from @options, but AR's UniquenessValidator reads
    # options[:class] from the Hash passed to new — without the merge a
    # worker-side rebuild raises on @klass.singleton_class?).
    def self.build_validator_descriptor(validator, declaring_class = nil)
      options = validator.options
      attributes = validator.respond_to?(:attributes) ? validator.attributes : nil
      desc_options =
        if options.is_a?(::Hash)
          options.dup
        elsif declaring_class
          {}
        end
      if desc_options && declaring_class && !desc_options.key?(:class)
        desc_options[:class] = declaring_class
      end
      descriptor = {
        validator: validator.class.name,
        attributes: (attributes.map(&:to_sym).freeze if attributes),
        options: (desc_options.freeze if desc_options)
      }
      Ractor.make_shareable(descriptor)
      descriptor
    rescue StandardError, Ractor::IsolationError
      funnel.call("unshareable validator #{validator.class.name}") do
        warn "[ractor_rails_shim] validator #{validator.class.name} has unshareable options — " \
             "its callback will not replay in worker Ractors"
      end if RactorRailsShim.debug?
      nil
    end

    # Debug-visible skip marker for a captured-callback declaration that was
    # NOT recorded (unresolvable Proc if:/unless:, unshareable validator
    # options). Silent unless debug — the shim's skip-and-continue philosophy.
    def self.log_unresolvable_callback(klass, chain_kind, filter)
      funnel.call("unresolvable callback #{klass.name}##{chain_kind}:#{filter.class}") do
        warn "[ractor_rails_shim] callback #{klass.name} #{chain_kind} filter #{filter.class} has " \
             "unresolvable conditions/options — it will not replay in worker Ractors"
      end if RactorRailsShim.debug?
      nil
    end

    # Clear the declared-callbacks table. Test seam.
    def self.reset_declared_callbacks!
      remove_instance_variable(:@declared_callbacks) if instance_variable_defined?(:@declared_callbacks)
    end

    # Install an interceptor on ActiveSupport::Callbacks.set_callback that
    # records, per declaring class, every symbolic `:process_action` filter
    # it declares. This must run BEFORE eager load (so declarations are
    # captured as they happen) — install wires it via the
    # ActiveSupport.on_load(:active_support) hook in `install`.
    def self.install_callback_declaration_capture!
      return if @installed
      register_patch.call(:action_filter_introspection, "8.1")
      @installed = true
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
          # Capture any SHAREABLE filter on an app class — controller
          # (AbstractController::Base) OR ActiveRecord model (including
          # ActiveRecord::Base's own framework declarations) — for ANY
          # callback chain kind (:process_action, :save, :create, :destroy,
          # :validate, …). Two filter shapes are capturable:
          #
          #   1. Symbolic filters (shareable method names) — re-invoked in
          #      worker Ractors via the SymbolicTransport.
          #   2. Validator-OBJECT filters (ActiveModel::Validator instances
          #      registered by `validates` / `validates_with` /
          #      `validates_associated`) — recorded as a shareable
          #      {validator-class-name, attributes, options} descriptor; the
          #      transport rebuilds a fresh validator in the worker and calls
          #      .validate(record). This is what makes worker-side
          #      `valid?` actually run validations (row 1).
          #
          # Lambda/block filters are unshareable and are left in the (empty
          # in workers) chain — they need a dedicated transport (e.g. the
          # dependent-association transport). Capturing ALL kinds (not just
          # :process_action) is what generalizes the transport to any
          # callback.
          if filters.length >= 1 && self.is_a?(::Class) &&
             (
               (self.ancestors.include?(::AbstractController::Base) rescue false) ||
               (defined?(::ActiveRecord::Base) && (self <= ::ActiveRecord::Base))
             ) &&
             (filters[0].is_a?(Symbol) ||
              (defined?(::ActiveModel::Validator) && filters[0].is_a?(::ActiveModel::Validator)))
            # Rails' set_callback(name, *filter_list) passes the phase
            # (:before/:after/:around) as filter_list[0] only when explicitly
            # given (the macro callbacks always do); otherwise the phase
            # defaults to :before and filter_list[0] IS the filter — see
            # normalize_callback_params. The old interceptor assumed an
            # explicit phase unconditionally, so no-phase declarations
            # (`validate :my_check`, `set_callback(:validate, validator)`)
            # were silently missed.
            if %i(before after around).include?(filters[0])
              phase = filters[0]
              rest = filters[1..]
            else
              phase = :before
              rest = filters
            end
            filter = rest[0]
            opts = rest.find { |f| f.is_a?(::Hash) }
            if filter.is_a?(Symbol)
              only = nil
              except = nil
              if opts
                [opts[:if], opts[:unless]].each do |arr|
                  next unless arr.is_a?(::Array)
                  arr.each do |af|
                    ck, acts = ::RactorRailsShim::CallbackCapture.read_action_filter_constraints(af)
                    next unless ck && acts
                    only = acts if ck == :only
                    except = acts if ck == :except
                  end
                end
              end
              if_cond, unless_cond, on_keys, except_on_keys, all_resolvable =
                ::RactorRailsShim::CallbackCapture.decode_callback_conditions(opts)
              # A callback whose if:/unless: contains an unresolvable Proc
              # (e.g. Rails' encryption guard `if: -> { has_encrypted_
              # attributes? && … }`) CANNOT be replayed faithfully: it would
              # run unconditionally in workers where the real chain gates it.
              # Skip the capture (fail-safe — never over-runs) and warn under
              # debug.
              if all_resolvable
                ::RactorRailsShim::CallbackCapture.record_declared_callback(
                  self.object_id, name, phase, filter, only, except, if_cond, unless_cond, on_keys, except_on_keys)
              else
                ::RactorRailsShim::CallbackCapture.log_unresolvable_callback(self, name, filter)
              end
            elsif (defined?(::ActiveModel::Validator) && filter.is_a?(::ActiveModel::Validator)) && phase != :around
              # Validator-object filter. Build a shareable descriptor; on
              # failure (validator options hold unshareable state, e.g. a
              # custom validator capturing Procs) skip the capture — the
              # validator does NOT replay in workers (fail-safe: never
              # over-runs). Around-phase validators are not replayable by
              # this transport (no block suspension) and are skipped.
              if_cond, unless_cond, on_keys, except_on_keys, all_resolvable =
                ::RactorRailsShim::CallbackCapture.decode_callback_conditions(opts)
              descriptor = all_resolvable &&
                           ::RactorRailsShim::CallbackCapture.build_validator_descriptor(filter, opts && opts[:class])
              if descriptor
                ::RactorRailsShim::CallbackCapture.record_declared_validator_callback(
                  self.object_id, name, phase, descriptor, if_cond, unless_cond, on_keys, except_on_keys)
              else
                ::RactorRailsShim::CallbackCapture.log_unresolvable_callback(self, name, filter)
              end
            end
          end
          _rrs_orig_set_callback(name, *filters, &block)
        end
      RUBY
      @installed = true
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

    # Read an ivar; if it's undefined, behavior is gated by the
    # VersionPolicy::Strategy (Issue #37 — the `case policy` branch is
    # replaced by a strategy-module message):
    #   Strict — raise UnsupportedVersionError (a missing ivar means
    #            callbacks run for actions they shouldn't; failing loud
    #            pins the security-relevant failure mode instead of
    #            silently mis-routing callbacks)
    #   Warn   — emit a labeled warning via funnel when debug? so a silent
    #            Rails internal rename surfaces during diagnosis
    #   Off    — silent nil
    # Returns the ivar value or nil (under Warn/Off).
    def self.read_ivar_or_warn(obj, ivar, label)
      return obj.instance_variable_get(ivar) if obj.instance_variable_defined?(ivar)
      RactorRailsShim::VersionPolicy.strategy.missing_ivar(obj, ivar, label, funnel: funnel)
    end
  end
end