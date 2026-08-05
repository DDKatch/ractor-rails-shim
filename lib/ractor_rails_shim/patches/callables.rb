# frozen_string_literal: true

# Callable / lock-replacement object model. These classes are shareable
# stand-ins for unshareable Rails internals (self-capturing Procs, Mutexes,
# IO-backed log devices) that make_app_shareable! swaps into the app graph
# before Ractor.make_shareable. Extracted from make_shareable.rb so the
# object model has its own home.
#
# Defined on RactorRailsShim's singleton class (the same access path the rest
# of the codebase uses: RactorRailsShim.singleton_class.const_get(:NoOpProc)).

module RactorRailsShim
  class << self
    class NoOpProc
      def call(*_); nil; end
      # A NoOpProc is a shareable stand-in for an arbitrary Proc in the app
      # graph. Some Rails code passes such values through `&block`, which
      # calls `#to_proc` and then requires the result to be a real Proc.
      # Return a frozen no-op lambda so the implicit conversion succeeds and
      # the (side-effect-free) call is a true no-op, matching `#call`.
      #
      # The lambda is a shareable constant (frozen at class load), NOT
      # memoized on `@_to_proc`: NoOpProc instances are deep-frozen by
      # `Ractor.make_shareable` during `make_app_shareable!`, so an
      # `@_to_proc ||= ...` write would raise FrozenError on the frozen
      # instance. A constant avoids the write entirely and is safe to share.
      NO_OP_LAMBDA = ->(*) { nil }.freeze
      Ractor.make_shareable(NO_OP_LAMBDA)
      def to_proc
        NO_OP_LAMBDA
      end
    end

    class Callable
      def initialize(target, method_name)
        @target = target
        @method_name = method_name
      end
      def call(*args)
        @target.__send__(@method_name, *args)
      end
    end

    class CallableConst
      def initialize(value); @value = value; end
      def call(*_); @value; end
    end

    # Shareable snapshot of a Devise::Mapping. The real Mapping holds an
    # unshareable lambda (failure_app) plus a default-proc Hash (controllers),
    # so it can't be Ractor.make_shareable'd. Request-time code only reads a
    # handful of attributes (name, to/class, router_name, controllers, ...),
    # which are all shareable values. We copy those now (in main) into a
    # frozen Plain Old Object that plays the role of the Mapping in workers.
    class DeviseMappingSnapshot
      def initialize(mapping)
        @name         = mapping.name
        @klass        = mapping.to
        @router_name  = mapping.instance_variable_get(:@router_name)
        @singular     = mapping.instance_variable_get(:@singular)
        @scoped_path  = mapping.instance_variable_get(:@scoped_path)
        @path         = mapping.instance_variable_get(:@path)
        @path_prefix  = mapping.instance_variable_get(:@path_prefix)
        @format       = mapping.instance_variable_get(:@format)
        @sign_out_via = mapping.instance_variable_get(:@sign_out_via)
        @modules      = mapping.modules
        @strategies   = mapping.strategies
        @routes       = mapping.routes
        @used_helpers = mapping.used_helpers
        # controllers is a Hash with a default proc (unshareable) — copy the
        # entries into a plain frozen Hash.
        h = {}
        RactorRailsShim._swallow("devise mapping controllers") do
          mapping.controllers.each { |k, v| h[k] = v }
        end
        @controllers = h.freeze
        # failure_app is either Devise::FailureApp (a shareable class) or a
        # lambda (when configured as a String) — keep only the shareable class.
        fa = mapping.instance_variable_get(:@failure_app)
        fa = ::Devise::FailureApp unless fa.is_a?(Class)
        @failure_app = fa
        freeze
      end

      def name; @name; end
      def to; @klass; end
      def router_name; @router_name; end
      def singular; @singular; end
      def scoped_path; @scoped_path; end
      def path; @path; end
      def path_prefix; @path_prefix; end
      def format; @format; end
      def sign_out_via; @sign_out_via; end
      def modules; @modules; end
      def strategies; @strategies; end
      def routes; @routes; end
      def used_helpers; @used_helpers; end
      def controllers; @controllers; end
      def failure_app; @failure_app; end
      def authenticatable?; @modules.any? { |m| m.to_s =~ /authenticatable/ }; end
      def no_input_strategies; @strategies & Devise::NO_INPUT; end
      def fullpath; "/#{@path_prefix}/#{@path}".squeeze("/"); end

      # Explicit `x?` predicates for Devise's standard module set
      # (devise-5.x/lib/devise/modules.rb). Defining these as real methods
      # makes the message-based contract visible — a reader can see which
      # predicates the snapshot answers without grepping Devise, and
      # `method_defined?` returns true for them. Each returns true iff the
      # module Symbol is in `@modules`, matching the generated
      # `Devise::Mapping#x?` behaviour exactly.
      def database_authenticatable?; @modules.include?(:database_authenticatable); end
      def rememberable?;             @modules.include?(:rememberable);             end
      def omniauthable?;             @modules.include?(:omniauthable);             end
      def recoverable?;              @modules.include?(:recoverable);              end
      def registerable?;             @modules.include?(:registerable);             end
      def validatable?;              @modules.include?(:validatable);              end
      def confirmable?;              @modules.include?(:confirmable);              end
      def lockable?;                 @modules.include?(:lockable);                 end
      def timeoutable?;              @modules.include?(:timeoutable);              end
      def trackable?;                @modules.include?(:trackable);                end

      # Fallback for custom modules added via `Devise.add_module` by
      # third-party gems. The standard set is handled by the explicit
      # methods above; anything else falls through here, answering `x?`
      # predicates by checking `@modules` — matching the generated
      # `Devise::Mapping.add_module` behaviour for non-standard modules.
      def respond_to_missing?(method, _)
        method.to_s.end_with?("?") || super
      end

      def method_missing(method, *args)
        s = method.to_s
        if s.end_with?("?") && args.empty?
          @modules.include?(s.chomp("?").to_sym)
        else
          super
        end
      end
    end

    def _devise_mapping_snapshot(mapping)
      _swallow("devise mapping snapshot") { DeviseMappingSnapshot.new(mapping) }
    end

    class NoOpLock
      def synchronize; yield; end
      def mon_synchronize; yield; end
      def lock; self; end
      def unlock; self; end
      def locked?; false; end
      def mon_enter; end
      def mon_exit; end
      def mon_locked?; false; end
      def try_lock; true; end
      # Returns a NoOpCond — a shareable, no-op stand-in for the
      # MonitorMixin::ConditionVariable-like object that `lock.new_cond`
      # yields in Rails' own Concurrent::Map / Monitor usage. Each method
      # is a true no-op so callers that `cond.wait` / `cond.signal` /
      # `cond.broadcast` from a worker Ractor don't block or touch
      # unshareable state. Replaces the anonymous
      # `Struct.new(:wait, :signal, :broadcast).new(-> {}, -> {}, -> {})`
      # — same duck-typing shape, but a named class so the condvar
      # contract is visible to readers (Issue #11).
      def new_cond; NoOpCond.new; end
    end

    class NoOpCond
      def wait(*_); nil; end
      def signal; nil; end
      def broadcast; nil; end
    end

    # No-op log device sink: a frozen, shareable stand-in for an IO, swapped
    # in for $stdout/$stderr in the app's logger before make_shareable so
    # the real IOs aren't frozen. Responds to the write methods a
    # Logger::LogDevice might call.
    class NoOpLogDev
      def write(*_); self; end
      def <<(*_); self; end
      def puts(*_); self; end
      def print(*_); self; end
      def flush; self; end
      def close; self; end
      def sync=(*_); self; end
      def binmode; self; end
      def tty?; false; end
      def closed?; false; end
    end
  end
end