# frozen_string_literal: true

# Patch Warden::Hooks lazy class-ivar accessors (@_on_request ||= [] etc).
# Warden middleware holds 6 lazy-init class ivars for callback arrays.
# make_app_shareable! freezes the middleware instance; the ||= lazy init
# tries to WRITE on the frozen instance → IsolationError in workers.
# The callbacks (Procs) were registered at boot and already ran in main;
# workers treat them as empty (correct for a read-only shared app).

module RactorRailsShim
  # Devise constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "Devise::ParameterSanitizer::DEFAULT_PERMITTED_ATTRIBUTES",
    "Devise::Mapping::DEFAULTS",
    "Devise::DEVS",
    "Devise::URLS",
    "Devise::STRATEGIES",
    "Devise::CONTROLLERS",
    "Devise::MODULES",
  ])

  # Source-location constant for the Devise scope constraint Proc (moved from
  # make_shareable.rb so the Devise-related callable lives with the Devise patch).
  DEVISE_SCOPE_LOC = "/devise/rails/routes.rb".freeze

  class << self
    def _install_warden_hooks_patch
      return if @warden_patched
      @warden_patched = true
      _register_patch :warden_hooks, "8.1"
      return unless defined?(::Warden::Hooks)
      ::Warden::Hooks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _after_set_user
          if Ractor.main? && instance_variable_defined?(:@_after_set_user)
            @_after_set_user
          else
            []
          end
        end
        def _before_failure
          if Ractor.main? && instance_variable_defined?(:@_before_failure)
            @_before_failure
          else
            []
          end
        end
        def _after_failed_fetch
          if Ractor.main? && instance_variable_defined?(:@_after_failed_fetch)
            @_after_failed_fetch
          else
            []
          end
        end
        def _before_logout
          if Ractor.main? && instance_variable_defined?(:@_before_logout)
            @_before_logout
          else
            []
          end
        end
        def _on_request
          if Ractor.main? && instance_variable_defined?(:@_on_request)
            @_on_request
          else
            []
          end
        end
      RUBY
    end

    # Patch Warden::Strategies#_strategies. The strategy registry is a lazy
    # class ivar (`@strategies ||= {}`) on the Warden::Strategies module; a
    # worker Ractor reading it raises "can not get unshareable values from
    # instance variables of classes/modules from non-main Ractors" (Devise's
    # `current_user` / `user_signed_in?` in a layout hits
    # Warden::Strategies[label] -> _strategies). Capture the (shareable)
    # registry in main and expose it via a constant that workers read.
    def _install_warden_strategies_patch
      return if @warden_strategies_patched
      @warden_strategies_patched = true
      _register_patch :warden_strategies, "8.1"
      return unless defined?(::Warden::Strategies)
      ::Warden::Strategies.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _strategies
          if Ractor.main?
            @strategies ||= {}
          else
            RactorRailsShim::SHAREABLE_WARDEN_STRATEGIES || {}
          end
        end
      RUBY
      if Ractor.main?
        begin
          strat = ::Warden::Strategies.instance_variable_get(:@strategies)
          strat = Ractor.make_shareable(strat) if strat && !Ractor.shareable?(strat)
          RactorRailsShim.const_set(:SHAREABLE_WARDEN_STRATEGIES, strat) unless RactorRailsShim.const_defined?(:SHAREABLE_WARDEN_STRATEGIES)
        rescue
          nil
        end
      end
    end

    # Warden registers per-scope session serializers with
    # `Warden::SessionSerializer.send(:define_method, method_name, &block)`
    # (warden-1.2.9/lib/warden/manager.rb:71). The block is created while the
    # app boots in the main Ractor, so the resulting method is Ractor-bound:
    # invoking it (e.g. `user_serialize`) from a worker Ractor raises
    # "defined with an un-shareable Proc in a different Ractor".
    #
    # Devise's block body is simply `mapping.to.serialize_into_session(record)`.
    # We re-register the serializers as plain `def` methods (which are NOT
    # Ractor-bound) that delegate to the model class's own
    # `serialize_into_session` / `serialize_from_session` class methods — both
    # worker-safe — so the chain is callable from any worker Ractor.
    def _install_warden_serializer_patch
      return if @warden_serializer_patched
      @warden_serializer_patched = true
      _register_patch :warden_serializer, "8.1"
      return unless defined?(::Warden::SessionSerializer)

      if defined?(::Devise) && ::Devise.respond_to?(:mappings)
        ::Devise.mappings.each do |scope, mapping|
          model = mapping.to
          ::Warden::SessionSerializer.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{scope}_serialize(record)
              #{model}.serialize_into_session(record)
            end

            def #{scope}_deserialize(*keys)
              # Devise's serialize_into_session returns [[id], salt]. The key
              # passed by Warden::SessionSerializer#fetch is that value, but in
              # the kino :ractor worker the per-request session that Warden's
              # serializer sees can hold an extra wrapping layer
              # ([[[id], salt]]). Flatten so serialize_from_session(key, salt)
              # always receives exactly two arguments.
              #{model}.serialize_from_session(*keys.flatten)
            end
          RUBY
        end
      end

      ::Warden::SessionSerializer.class_eval do
        unless method_defined?(:serialize)
          def serialize(user)
            user
          end
        end

        unless method_defined?(:deserialize)
          def deserialize(key)
            key
          end
        end
      end
    end

    # --- Devise scope-constraint callable (moved from make_shareable.rb) ---
    # Defined via string eval on the singleton class so it's referenced the same
    # way the original code did (RactorRailsShim.singleton_class.const_get).
    module_eval <<-RUBY, __FILE__, __LINE__ + 1
      class DeviseMappingCallable
        def initialize(mapping); @mapping = mapping; end
        def call(request)
          request.env["devise.mapping"] = @mapping
          true
        end
      end
    RUBY

    # Build a shareable replacement for a Devise scope constraint.
    # The original Proc (devise/rails/routes.rb:363) does:
    #   request.env["devise.mapping"] = Devise.mappings[scope]
    #   true
    # The scope is captured in the Proc's binding. We call the original
    # Proc once in main with a mock request to capture the mapping, then
    # make it shareable and wrap it in a DeviseMappingCallable.
    def _devise_mapping_replacement(proc_obj, _parent)
      mock_env = { "devise.mapping" => nil }
      mock_req = Struct.new(:env).new(mock_env)
      begin
        proc_obj.call(mock_req)
      rescue
      end
      mapping = mock_env["devise.mapping"]
      if mapping
        mapping = _devise_mapping_snapshot(mapping)
      end
      if mapping
        DeviseMappingCallable.new(mapping)
      else
        CallableConst.new(true)
      end
    end
  end
end
