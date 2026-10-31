# frozen_string_literal: true

# Patch Jbuilder's global class state for worker Ractors.
#
# Blocker 1 — `JbuilderTemplate.template_lookup_options`: a class ivar holding
# an UNFROZEN mutable Hash (set at load: `self.template_lookup_options =
# { handlers: [:jbuilder] }`). Every partial render reads it
# (`options[:handlers] ||=
# ::JbuilderTemplate.template_lookup_options[:handlers]`) — a worker reading a
# class ivar holding a mutable Hash raises Ractor::IsolationError.
# Fix: deep-freeze the value at install time (install runs in main, after the
# load-time assignment). A frozen Hash of Symbols is Ractor.shareable, so
# worker reads are safe.
#
# Blocker 2 — the three `@@` class variables on `Jbuilder`
# (`@@key_formatter`, `@@ignore_nil`, `@@deep_format_keys`). `Jbuilder.new`
# reads them as its keyword-default arguments on EVERY render — raw cvar reads
# inside the default-argument expressions, so a worker call raises before the
# body even runs. These accessors are plain singleton methods, NOT
# mattr_accessor, so the shim's macro rewrite doesn't catch them.
#
# Fix (capture-and-replay, like CallbackCapture):
#   * `Jbuilder.new` is redefined with a sentinel default (`UNSET`), so the
#     default arguments never read a cvar. MAIN then resolves the originals
#     from the class variables (upstream semantics). WORKERS resolve from
#     shareable CAPTURES:
#       - `ignore_nil` / `deep_format_keys`: the booleans the setters recorded.
#       - `key_formatter`: a per-worker `KeyFormatter` rebuilt from the
#         options previously passed to `Jbuilder.key_format` — the options
#         list is captured when shareable, so each worker gets a formatter
#         with its OWN Mutex and cache (never shared). Options containing an
#         un-shareable lambda can't cross the boundary; the capture stays
#         unset and workers use upstream's nil-formatter default instead.
#   * The setters capture at CALL time (main Ractor — boot/initializer time,
#     where apps configure Jbuilder), so captures are populated before the
#     graph is frozen. No freeze-time hook needed.
#
# In main every reader produces exactly what the original code produced.

module RactorRailsShim
  class << self
    def _install_jbuilder_patch
      return if @jbuilder_patched
      @jbuilder_patched = true
      _register_patch :jbuilder, "8.1"
      return unless defined?(::Jbuilder) && defined?(::JbuilderTemplate)

      _freeze_jbuilder_template_lookup_options!
      _seed_jbuilder_captures
      _install_jbuilder_setters
      _install_jbuilder_worker_safe_initialize
      true
    end

    # Called from the intercepted Jbuilder.key_format (the eval'd override
    # runs with an explicit receiver, so this must be public despite the
    # underscore).
    def _capture_jbuilder_key_format!(formats)
      return unless formats.is_a?(::Array)
      shareable = ::Ractor.make_shareable(formats) rescue nil
      _reassign_shareable_const(:JBUILDER_KEY_FORMATS, shareable) if shareable
    end

    # Called from the eval'd worker-safe Jbuilder#initialize (explicit
    # receiver — public despite the underscore). Rebuilds the formatter per
    # worker from the captured (shareable) options.
    def _worker_jbuilder_key_formatter
      formats = begin
        ::RactorRailsShim::JBUILDER_KEY_FORMATS
      rescue ::NameError
        nil
      end
      return nil unless formats.is_a?(::Array) && !formats.empty?
      ::Jbuilder::KeyFormatter.new(*formats)
    end

    private

    # Freeze the template-lookup options value so worker reads are safe.
    def _freeze_jbuilder_template_lookup_options!
      return unless ::JbuilderTemplate.instance_variable_defined?(:@template_lookup_options)
      current = ::JbuilderTemplate.instance_variable_get(:@template_lookup_options) || {handlers: [:jbuilder]}
      return if ::Ractor.shareable?(current)
      frozen = current.each_with_object({}) { |(k, v), h| h[k] = v.freeze }.freeze
      ::JbuilderTemplate.template_lookup_options = frozen
    end

    # Always define the capture constants so the eval'd #initialize can
    # reference them even when the app never calls the setters. Existing
    # cvar values (set before install) are honored for the booleans; the
    # formatter options cannot be recovered from a KeyFormatter instance
    # post-hoc, so that capture starts empty and is filled by the setter.
    def _seed_jbuilder_captures
      _reassign_shareable_const(:JBUILDER_IGNORE_NIL, ::Ractor.make_shareable(jbuilder_cvar(:@@ignore_nil, false)))
      _reassign_shareable_const(:JBUILDER_DEEP_FORMAT_KEYS, ::Ractor.make_shareable(jbuilder_cvar(:@@deep_format_keys, false)))
      _reassign_shareable_const(:JBUILDER_KEY_FORMATS, [].freeze)
    end

    def jbuilder_cvar(name, default)
      value = ::Jbuilder.class_variable_get(name)
      value.nil? ? default : value
    rescue ::NameError
      default
    end

    # Intercept the DSL setters (alias first — a same-class override makes
    # `super` skip the original, which we must not lose) to capture the state
    # into shareable constants for the workers. The DSL setters live in the
    # top-level jbuilder.rb (`require "jbuilder"`), not in
    # jbuilder/jbuilder.rb's core class — guard each so a core-only load
    # (template partial use without the main file) is a no-op.
    def _install_jbuilder_setters
      singleton = ::Jbuilder.singleton_class
      if singleton.method_defined?(:ignore_nil)
        singleton.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_shim_original_ignore_nil, :ignore_nil unless method_defined?(:_shim_original_ignore_nil)
          def ignore_nil(value = true)
            result = _shim_original_ignore_nil(value)
            if ::Ractor.main?
              ::RactorRailsShim._reassign_shareable_const(
                :JBUILDER_IGNORE_NIL, ::Ractor.make_shareable(@@ignore_nil || false)
              )
            end
            result
          end
        RUBY
      end
      if singleton.method_defined?(:deep_format_keys)
        singleton.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_shim_original_deep_format_keys, :deep_format_keys unless method_defined?(:_shim_original_deep_format_keys)
          def deep_format_keys(value = true)
            result = _shim_original_deep_format_keys(value)
            if ::Ractor.main?
              ::RactorRailsShim._reassign_shareable_const(
                :JBUILDER_DEEP_FORMAT_KEYS, ::Ractor.make_shareable(@@deep_format_keys || false)
              )
            end
            result
          end
        RUBY
      end
      if singleton.method_defined?(:key_format)
        singleton.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_shim_original_key_format, :key_format unless method_defined?(:_shim_original_key_format)
          def key_format(*formats)
            result = _shim_original_key_format(*formats)
            ::RactorRailsShim._capture_jbuilder_key_format!(formats) if ::Ractor.main?
            result
          end
        RUBY
      end
      true
    end

    # Worker-safe `Jbuilder.new`: the sentinel default means the cvar reads in
    # the upstream signature never execute. Main keeps upstream semantics
    # (read the class variables); workers use the captured constants.
    # NOTE: every constant/method reference in eval'd code uses a leading
    # `::` (or a Jbuilder-scoped helper) — bare cref-rooted names do not
    # resolve to Object's top-level table from inside a worker Ractor.
    def _install_jbuilder_worker_safe_initialize
      ::Jbuilder.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def initialize(key_formatter: ::RactorRailsShim::UNSET, ignore_nil: ::RactorRailsShim::UNSET, deep_format_keys: ::RactorRailsShim::UNSET, &block)
          @attributes = {}
          if ::Ractor.main?
            key_formatter = @@key_formatter if key_formatter.equal?(::RactorRailsShim::UNSET)
            ignore_nil = @@ignore_nil if ignore_nil.equal?(::RactorRailsShim::UNSET)
            deep_format_keys = @@deep_format_keys if deep_format_keys.equal?(::RactorRailsShim::UNSET)
          else
            key_formatter = ::Jbuilder._shim_worker_key_formatter if key_formatter.equal?(::RactorRailsShim::UNSET)
            ignore_nil = ::RactorRailsShim::JBUILDER_IGNORE_NIL if ignore_nil.equal?(::RactorRailsShim::UNSET)
            deep_format_keys = ::RactorRailsShim::JBUILDER_DEEP_FORMAT_KEYS if deep_format_keys.equal?(::RactorRailsShim::UNSET)
          end
          @key_formatter = key_formatter
          @ignore_nil = ignore_nil
          @deep_format_keys = deep_format_keys
          yield self if block
        end
      RUBY
      ::Jbuilder.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _shim_worker_key_formatter
          formats = begin
            ::RactorRailsShim::JBUILDER_KEY_FORMATS
          rescue ::NameError
            nil
          end
          return nil unless formats.is_a?(::Array) && !formats.empty?
          ::Jbuilder::KeyFormatter.new(*formats)
        end
      RUBY
    end
  end

  # Sentinel default-argument value for the patched Jbuilder#initialize.
  # Must be frozen + shareable (it flows through worker calls untouched).
  UNSET = Object.new.freeze
  ::Ractor.make_shareable(UNSET)
end
