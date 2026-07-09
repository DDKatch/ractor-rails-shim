# frozen_string_literal: true

# Patches for ActionView: LookupContext (default_formats defined via
# define_method(&block)), Template::Handlers, and PathRegistry.

module RactorRailsShim
  # ActionView constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActionView::LookupContext::Accessors::DEFAULT_PROCS",
  ])

  class << self
    def _install_lookup_context_patch
      return if @lookup_context_patched
      @lookup_context_patched = true
      _register_patch :lookup_context, "8.1"
      return unless defined?(::ActionView::LookupContext)
      lc = ::ActionView::LookupContext
      key = :ractor_rails_shim_lookup_context_registered_details
      key_str = key.inspect
      lc.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def registered_details
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@registered_details)
            @registered_details
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}] || []
          end
        end
        def registered_details=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
          @registered_details = val if Ractor.main?
          val
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionView::LookupContext", :registered_details, key, []]

      # Redefine default_#{name} methods. register_detail (line 25 of
      # lookup_context.rb) defines these via Accessors.define_method(:"default_#{name}", &block)
      # — a Proc from the main ractor. Calling them from a worker raises
      # "defined with an un-shareable Proc in a different Ractor".
      # Trigger: when Accept: */* is sent, request.formats returns [Mime::ALL],
      # and LookupContext#formats= (the override at line 263) does
      # `values.concat(default_formats) if values.delete "*/*"` — Mime::ALL
      # compares == to "*/*", so delete removes it and default_formats is called.
      # Fix: call each block once in main, make the result shareable, and
      # redefine the method via string eval (no captured binding).
      accessors = ::ActionView::LookupContext::Accessors
      ::ActionView::LookupContext.registered_details.each do |name|
        block = accessors::DEFAULT_PROCS[name]
        next unless block
        begin
          value = block.call
        rescue
          next
        end
        begin
          value = Ractor.make_shareable(value)
        rescue
          value = value.dup.freeze rescue value
        end
        const_name = "SHIM_DEFAULT_#{name.upcase}_VALUE"
        verbose, $VERBOSE = $VERBOSE, nil
        accessors.const_set(const_name, value)
        $VERBOSE = verbose
        accessors.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def default_#{name}
            ::ActionView::LookupContext::Accessors::#{const_name}
          end
        RUBY
      end

      # Patch ActionView::Rendering::ClassMethods#view_context_class to read
      # from a shareable registry (populated in main) instead of building via
      # Class.new{...} blocks (un-shareable Proc from a worker). The built
      # class is made shareable; workers read it via the registry.
      if defined?(::ActionView::Rendering::ClassMethods)
        rcm = ::ActionView::Rendering::ClassMethods

        # Capture the ORIGINAL view_context_class BEFORE patching, so we can
        # build per-controller classes in main using the original logic.
        orig_vcc = rcm.instance_method(:view_context_class)

        # Populate the registry: call the ORIGINAL view_context_class for each
        # loaded controller in main, capture the built class. Done BEFORE
        # patching so ctrl.view_context_class hits the original.
        if Ractor.main?
          registry = {}
          ::AbstractController::Base.descendants.each do |ctrl|
            begin
              vc = orig_vcc.bind(ctrl).call
              registry[ctrl] = vc
            rescue => e
              # skip controllers that can't build (e.g. abstract)
            end
          end
          registry.delete_if { |_, v| v.nil? }
          registry.freeze
          begin
            Ractor.make_shareable(registry)
            self._view_context_registry = registry
          rescue => e
            # If the registry can't be made shareable, leave it — workers fall
            # back to the empty-cache base.
          end
        end

        rcm.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def view_context_class
            reg = RactorRailsShim._view_context_registry
            v = reg[self] if reg
            return v if v
            if Ractor.main? && instance_variable_defined?(:@view_context_class)
              @view_context_class
            else
              # No registry entry (e.g. a controller loaded after prepare).
              # Fall back to the DetailsKey view_context_class (the empty-cache
              # base) — rendering may fail for controllers needing url_helpers,
              # but simple render :plain works.
              ActionView::LookupContext::DetailsKey.view_context_class
            end
          end
        RUBY
      end
      vcc_key = :ractor_rails_shim_lookup_context_view_context_class
      vcc_key_str = vcc_key.inspect
      CLASS_ATTRIBUTES << ["ActionView::LookupContext::DetailsKey", :view_context_class, vcc_key, nil]
      # Build it now in main and stash in IES so the fallback builder picks it up.
      if Ractor.main? && defined?(::ActionView::Base)
        built = ::ActionView::LookupContext::DetailsKey.view_context_class
        built.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def compiled_method_container; self.class; end
        RUBY
        built.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def compiled_method_container; self; end
        RUBY
        ActiveSupport::IsolatedExecutionState[vcc_key] = built
      end

      dk = ::ActionView::LookupContext::DetailsKey
      dk_key = :ractor_rails_shim_lookup_context_details_keys
      dc_key = :ractor_rails_shim_lookup_context_digest_cache
      dk_key_str = dk_key.inspect
      dc_key_str = dc_key.inspect
      vcc_key_str2 = vcc_key.inspect
      dk.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def view_context_class
          v = ActiveSupport::IsolatedExecutionState[#{vcc_key_str2}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@view_context_class)
            v = @view_context_class
            ActiveSupport::IsolatedExecutionState[#{vcc_key_str2}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{vcc_key_str2}]
          end
        end
        def details_keys
          v = ActiveSupport::IsolatedExecutionState[#{dk_key_str}]
          return v if v
          if Ractor.main? && instance_variable_defined?(:@details_keys)
            v = @details_keys
          else
            v = Concurrent::Map.new
          end
          ActiveSupport::IsolatedExecutionState[#{dk_key_str}] = v
          v
        end
        def digest_cache(details)
          dc = (ActiveSupport::IsolatedExecutionState[#{dc_key_str}] ||= Concurrent::Map.new)
          dc[details_cache_key(details)] ||= Concurrent::Map.new
        end
        def details_cache_key(details)
          details_keys.fetch(details) do
            if formats = details[:formats]
              unless Template::Types.valid_symbols?(formats)
                details = details.dup
                details[:formats] &= Template::Types.symbols
              end
            end
            details_keys[details] ||= TemplateDetails::Requested.new(**details)
          end
        end
      RUBY
    end

    def _install_template_handlers_patch
      return if @template_handlers_patched
      @template_handlers_patched = true
      _register_patch :template_handlers, "8.1"
      return unless defined?(::ActionView::Template::Handlers)
      h = ::ActionView::Template::Handlers
      th_key = :ractor_rails_shim_av_template_handlers
      ext_key = :ractor_rails_shim_av_template_extensions
      dth_key = :ractor_rails_shim_av_default_template_handlers
      th_key_str = th_key.inspect
      ext_key_str = ext_key.inspect
      dth_key_str = dth_key.inspect
      h.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def template_handlers_hash
          v = ActiveSupport::IsolatedExecutionState[#{th_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@template_handlers)
            cv = class_variable_get(:@@template_handlers)
            ActiveSupport::IsolatedExecutionState[#{th_key_str}] = cv
            cv
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{th_key_str}] || {}
          end
        end
        def extensions
          v = ActiveSupport::IsolatedExecutionState[#{ext_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@template_extensions)
            cv = class_variable_get(:@@template_extensions)
            cv ||= class_variable_get(:@@template_handlers).keys if class_variable_defined?(:@@template_handlers)
            ActiveSupport::IsolatedExecutionState[#{ext_key_str}] = cv
            cv
          else
            template_handlers_hash.keys
          end
        end
        def template_handler_extensions
          template_handlers_hash.keys.map(&:to_s).sort
        end
        def registered_template_handler(extension)
          extension && template_handlers_hash[extension.to_sym]
        end
        def handler_for_extension(extension)
          registered_template_handler(extension) || begin
            v = ActiveSupport::IsolatedExecutionState[#{dth_key_str}]
            if v.nil?
              if Ractor.main? && class_variable_defined?(:@@default_template_handlers)
                v = class_variable_get(:@@default_template_handlers)
                ActiveSupport::IsolatedExecutionState[#{dth_key_str}] = v
              else
                v = RactorRailsShim::SHAREABLE_FALLBACK[#{dth_key_str}]
              end
            end
            v
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionView::Template::Handlers", :template_handlers, th_key, {}]
      CLASS_ATTRIBUTES << ["ActionView::Template::Handlers", :default_template_handlers, dth_key, nil]
    end

    # Patch ActionView::PathRegistry to not read its raw class ivars
    # (@view_paths_by_class, @file_system_resolvers) from a worker Ractor.
    # These are populated at boot (view paths registered by the app). For a
    # frozen shared app they're read-only; workers read them via the shareable
    # fallback (built from main's values, made shareable). `get_view_paths` is
    # called per-request during view lookup; `all_file_system_resolvers` is
    # called by the exception backtrace builder.
    def _install_path_registry_patch
      return if @path_registry_patched
      @path_registry_patched = true
      _register_patch :path_registry, "8.1"
      return unless defined?(::ActionView::PathRegistry)
      pr = ::ActionView::PathRegistry
      vpc_key = :ractor_rails_shim_path_registry_view_paths_by_class
      fsr_key = :ractor_rails_shim_path_registry_file_system_resolvers
      vpc_key_str = vpc_key.inspect
      fsr_key_str = fsr_key.inspect
      pr.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def get_view_paths(klass)
          h = ActiveSupport::IsolatedExecutionState[#{vpc_key_str}]
          h = (Ractor.main? ? (instance_variable_defined?(:@view_paths_by_class) ? instance_variable_get(:@view_paths_by_class) : {}) : RactorRailsShim::SHAREABLE_FALLBACK[#{vpc_key_str}]) if h.nil?
          h[klass] || get_view_paths(klass.superclass)
        end

        def set_view_paths(klass, paths)
          h = ActiveSupport::IsolatedExecutionState[#{vpc_key_str}] ||= (Ractor.main? ? (instance_variable_defined?(:@view_paths_by_class) ? instance_variable_get(:@view_paths_by_class) : {}) : {})
          h[klass] = paths
          instance_variable_set(:@view_paths_by_class, h) if Ractor.main?
        end

        def all_file_system_resolvers
          h = ActiveSupport::IsolatedExecutionState[#{fsr_key_str}]
          h = (Ractor.main? ? (instance_variable_defined?(:@file_system_resolvers) ? instance_variable_get(:@file_system_resolvers) : {}) : RactorRailsShim::SHAREABLE_FALLBACK[#{fsr_key_str}]) if h.nil?
          h.values
        end
      RUBY
      # Register so the fallback builder captures + shares these.
      CLASS_ATTRIBUTES << ["ActionView::PathRegistry", :view_paths_by_class, vpc_key, {}]
      CLASS_ATTRIBUTES << ["ActionView::PathRegistry", :file_system_resolvers, fsr_key, {}]
    end
  end
end
