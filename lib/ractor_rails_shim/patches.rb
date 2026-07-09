# frozen_string_literal: true

# The core shim: reroute Rails' class-level instance variable accessors
# through Ractor-safe storage.
#
# Background: Rails stores global state in class ivars:
#
#   class Rails
#     class << self
#       attr_accessor :app_class, :cache, :logger
#       def application; @application ||= ...; end
#     end
#   end
#
# From a non-main Ractor these reads/writes raise Ractor::IsolationError:
#   "can not get unshareable values from instance variables of classes/modules
#    from non-main Ractors"
#
# The fix: store the values in ActiveSupport::IsolatedExecutionState, which
# is already Ractor-safe. It's thread-local storage (Thread.current[:key]),
# and each Ractor has its own threads, so each Ractor gets its own slot.
# Verified on Ruby 4.0.5: a non-main Ractor reads nil for a key the main
# Ractor set, sets its own value without error, and main's value is intact.
#
# IMPORTANT: all method redefinitions use module_eval with STRING, not
# define_method with a block. A block captures the defining Ractor's
# binding, and calling it from another Ractor raises:
#   "defined with an un-shareable Proc in a different Ractor"
# String eval produces methods with no captured binding, callable from any
# Ractor. Verified on Ruby 4.0.5.

begin
  require "active_support/isolated_execution_state"
rescue LoadError
  # ActiveSupport not installed — the fallback below provides the same API.
end
require_relative "fallback_ies"

module RactorRailsShim
  # The keys under which each global is stored in IsolatedExecutionState.
  # Namespaced to avoid collisions with Rails' own uses of IES.
  KEYS = {
    application: :ractor_rails_shim_application,
    app_class: :ractor_rails_shim_app_class,
    cache: :ractor_rails_shim_cache,
    logger: :ractor_rails_shim_logger,
    env: :ractor_rails_shim_env,
    backtrace_cleaner: :ractor_rails_shim_backtrace_cleaner
  }.freeze

  class << self
    # Install all the patches. Safe to call multiple times (idempotent).
    def install
      install_rails_module
      install_mattr_accessor
      @installed = true
      true
    end

    def installed?
      @installed ||= false
    end

    private

    # Patch the Rails module's class-level accessors using module_eval
    # with strings (not define_method with blocks — see file header).
    def install_rails_module
      return unless defined?(::Rails)

      mod = ::Rails
      k = KEYS

      # application: lazy-init in main ractor; nil-until-set in workers.
      mod.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def application
          v = ActiveSupport::IsolatedExecutionState[#{k[:application].inspect}]
          return v unless v.nil?

          if Ractor.main?
            if instance_variable_defined?(:@application) && @application
              @application
            else
              @application = (app_class.instance if app_class)
              ActiveSupport::IsolatedExecutionState[#{k[:application].inspect}] = @application
              @application
            end
          else
            nil
          end
        end

        def application=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:application].inspect}] = val
          @application = val if Ractor.main?
          val
        end
      RUBY

      # Simple accessors: app_class, cache, logger, backtrace_cleaner.
      %i[app_class cache logger backtrace_cleaner].each do |name|
        key = k[name]
        ivar = :"@#{name}"
        mod.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{name}
            v = ActiveSupport::IsolatedExecutionState[#{key.inspect}]
            return v unless v.nil?
            if Ractor.main? && instance_variable_defined?(#{ivar.inspect})
              instance_variable_get(#{ivar.inspect})
            end
          end

          def #{name}=(val)
            ActiveSupport::IsolatedExecutionState[#{key.inspect}] = val
            instance_variable_set(#{ivar.inspect}, val) if Ractor.main?
            val
          end
        RUBY
      end

      # env: lazy init with a default from ENV.
      mod.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def env
          v = ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}]
          return v unless v.nil?

          if Ractor.main?
            if instance_variable_defined?(:@_env) && @_env
              @_env
            else
              @_env = ActiveSupport::EnvironmentInquirer.new(
                ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence || "development"
              )
              ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}] = @_env
              @_env
            end
          else
            v = ActiveSupport::EnvironmentInquirer.new(
              ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence || "development"
            )
            ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}] = v
            v
          end
        end

        def env=(val)
          v = ActiveSupport::EnvironmentInquirer.new(val)
          ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}] = v
          @_env = v if Ractor.main?
          v
        end
      RUBY
    end

    # Rewrite Module.mattr_accessor (and friends) so the accessor methods
    # route through IsolatedExecutionState. Uses prepend + module_eval with
    # strings to avoid cross-ractor binding issues.
    def install_mattr_accessor
      return if @mattr_patched
      @mattr_patched = true

      ::Module.prepend(Module.new {
        # The prepended module's body is evaluated in the main ractor at
        # prepend time; the methods it defines are callable from any ractor
        # because they're defined via string eval (no captured binding).
        # But mattr_accessor itself runs at app boot in the main ractor, and
        # the per-accessor redefinition must also use string eval.
        def mattr_accessor(*syms, instance_reader: true, instance_writer: true,
                           default: nil, **kwargs, &block)
          super # define the methods via the original path

          shareable = kwargs[:shareable]
          mod_name = name

          syms.each do |sym|
            key = :"ractor_rails_shim_mattr_#{mod_name}_#{sym}"
            key_str = key.inspect
            ivar = :"@#{sym}"
            ivar_str = ivar.inspect
            default_val = default.inspect if default
            has_default = !default.nil?

            # Redefine the class reader via string eval (no captured binding).
            singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{sym}
                v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                return v unless v.nil?

                if #{!!shareable}
                  instance_variable_get(#{ivar_str}) if instance_variable_defined?(#{ivar_str})
                elsif Ractor.main?
                  instance_variable_get(#{ivar_str}) if instance_variable_defined?(#{ivar_str})
                else
                  val = #{has_default ? default_val : 'nil'}
                  ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                  val
                end
              end

              def #{sym}=(val)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                instance_variable_set(#{ivar_str}, val) if Ractor.main?
                val
              end
            RUBY

            # Instance readers/writers route through the class methods.
            if instance_reader
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}; self.class.#{sym}; end
              RUBY
            end
            if instance_writer
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}=(val); self.class.#{sym} = val; end
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
  end
end