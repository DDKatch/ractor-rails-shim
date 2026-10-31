# frozen_string_literal: true

# Patch JSON::Validator (the json-schema gem) for worker Ractors. The whole
# gem's state is hand-written `@@` class variables on JSON::Validator — no
# mattr/class_attribute, so the shim's macro rewrites never see it. Every
# validation from a worker touches several of them.
#
# Runtime paths patched:
#
#   * `initialize` — reads `@@default_opts` (`clone.merge(opts)`: worker read
#     of a mutable Hash raises; and even frozen, `clone` PRESERVES frozen so
#     `merge` would raise), `@@cache_schemas` (bool — shareable), `@@mutex`
#     (a Mutex instance — unshareable), then `validator_for_name` /
#     `schema_reader` / `add_schema` / `schema_for_uri` / `schema_loaded?`.
#     Fix: worker branch of the redefined `initialize` — dup of the captured
#     frozen default-opts constant (dup drops the frozen flag, unlike clone),
#     NoOpLock instead of the Mutex, and the worker-safe readers below.
#     Main keeps the original statements byte-for-byte.
#   * `@@mutex` — replaced at install with a frozen NoOpLock: the Mutex only
#     protected threaded lazy schema building at BOOT (single-threaded), and
#     a frozen NoOpLock is shareable so the worker's raw cvar read works.
#   * `@@schemas` (+ `schemas` / `add_schema` / `schema_for_uri` /
#     `schema_loaded?` / `clear_cache`) — the schema cache is mutated at
#     runtime (`add_schema` per validator construction). Fix: per-Ractor
#     Hash via ::RactorRailsShim.storage; workers re-parse their schemas
#     locally (pure data work).
#   * `@@validators` / `@@default_validator` (+ `validators` /
#     `default_validator`) — boot-populated registry of draft-validator
#     instances; read by `validator_for_name`/`validator_for_uri` per
#     validation. Fix: shareable snapshot captured at install (deep-freeze,
#     with the proc/lock traversal as fallback); main keeps the live cvars.
#     When the snapshot can't freeze (custom formats holding user procs),
#     the constant is nil and workers raise the upstream SchemaError shape
#     for unknown versions instead of an IsolationError.
#   * `@@schema_reader` — lazily memoized (`||=` write off-main). Fix:
#     per-Ractor `JSON::Schema::Reader.new` via storage (config-only object).
#   * `@@serializer` / `@@fake_uuid_generator` — Proc cvars read+CALLED at
#     runtime by the private `serialize` / `fake_uuid` instance methods
#     (`@@serializer.call(schema)`). Fix: worker branches rebuild the
#     equivalent lambda Ractor-locally (json backend / Util::UUID paths);
#     main keeps the original.
#   * `@@json_backend` — read inside `parse`/`json_backend`. Fix: captured
#     frozen String constant for workers; main keeps the original.
#
# Worker semantics are preserved: schemas are re-parsed per Ractor, draft
# validators are shared frozen, and the JSON backend matches main's boot
# selection.

module RactorRailsShim
  class << self
    def _install_json_schema_patch
      return if @json_schema_patched
      @json_schema_patched = true
      _register_patch :json_schema, "8.1"
      return unless defined?(::JSON::Validator)

      _install_json_schema_validator_cvars
      _install_json_schema_accessors
      _install_json_schema_initialize
      _install_json_schema_private_procs
    end

    private

    # Swap the boot Mutex for a frozen NoOpLock on main (synchronize simply
    # yields — the lock only protected threaded boot-time schema building).
    # Workers never read `@@mutex`: class variables are unreadable off-main
    # even when shareable, so the worker branch of #initialize builds its
    # per-instance schema state without a lock.
    def _install_json_schema_validator_cvars
      return unless ::Ractor.main?
      lock = ::RactorRailsShim.singleton_class.const_get(:NoOpLock).new
      ::JSON::Validator.class_variable_set(:@@mutex, ::Ractor.make_shareable(lock))

      # Capture + freeze the boot registries. Draft validators are instances
      # holding only attribute-CLASS tables + frozen formats — freezable.
      # Custom user formats (register_format_validator) may hold procs: the
      # traversal fallback replaces those, else the capture stays nil.
      validators = ::JSON::Validator.class_variable_get(:@@validators) rescue nil
      if validators.is_a?(::Hash) && !validators.empty?
        frozen_validators = _json_schema_shareable_copy(validators)
        _reassign_shareable_const(:JSON_VALIDATORS, frozen_validators) if frozen_validators
      end
      default_validator = ::JSON::Validator.class_variable_get(:@@default_validator) rescue nil
      if default_validator
        frozen_default = _json_schema_shareable_copy(default_validator)
        _reassign_shareable_const(:JSON_DEFAULT_VALIDATOR, frozen_default) if frozen_default
      end
      backend = ::JSON::Validator.class_variable_get(:@@json_backend) rescue nil
      _reassign_shareable_const(:JSON_JSON_BACKEND, ::Ractor.make_shareable(backend.to_s.freeze)) if backend
      opts = ::JSON::Validator.class_variable_get(:@@default_opts) rescue nil
      _reassign_shareable_const(:JSON_DEFAULT_OPTS, ::Ractor.make_shareable(opts.dup.freeze)) if opts.is_a?(::Hash)
      use_multi = ::JSON::Validator.class_variable_get(:@@use_multi_json) rescue nil
      unless use_multi.nil?
        _reassign_shareable_const(:JSON_USE_MULTI_JSON, ::Ractor.make_shareable(use_multi == true))
      end
      # `JSON::Schema::Attribute.data_valid_for_type?` (reached on the
      # validate path) reads this String→Class mapping Hash; upstream leaves
      # it unfrozen, so workers die with IsolationError. Classes are
      # shareable — freezing is enough.
      mappings = ::JSON::Schema::Attribute.const_defined?(:TYPE_CLASS_MAPPINGS) &&
        ::JSON::Schema::Attribute.const_get(:TYPE_CLASS_MAPPINGS) rescue nil
      ::Ractor.make_shareable(mappings) if mappings.is_a?(::Hash) && !::Ractor.shareable?(mappings)
    end

    def _json_schema_shareable_copy(val)
      ::Ractor.make_shareable(val)
      val
    rescue ::StandardError
      begin
        ::RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(val)
        ::RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(val)
        ::Ractor.make_shareable(val)
        val
      rescue ::StandardError
        nil
      end
    end

    def _install_json_schema_accessors
      ::JSON::Validator.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def schema_reader
          if ::Ractor.main?
            @@schema_reader ||= JSON::Schema::Reader.new
          else
            key = :ractor_rails_shim_json_schema_reader
            ::RactorRailsShim.storage[key] ||= ::JSON::Schema::Reader.new
            ::RactorRailsShim.storage[key]
          end
        end

        def schemas
          if ::Ractor.main?
            @@schemas
          else
            key = :ractor_rails_shim_json_schemas
            ::RactorRailsShim.storage[key] ||= {}
            ::RactorRailsShim.storage[key]
          end
        end

        def add_schema(schema)
          if ::Ractor.main?
            @@schemas[schema_key_for(schema.uri)] ||= schema
          else
            key = :ractor_rails_shim_json_schemas
            ::RactorRailsShim.storage[key] ||= {}
            ::RactorRailsShim.storage[key][schema_key_for(schema.uri)] ||= schema
          end
        end

        def schema_for_uri(uri)
          if ::Ractor.main?
            @@schemas[uri] || @@schemas[schema_key_for(uri)]
          else
            cached = schemas
            cached[uri] || cached[schema_key_for(uri)]
          end
        end

        def schema_loaded?(schema_uri)
          !schema_for_uri(schema_uri).nil?
        end

        def clear_cache
          if ::Ractor.main?
            @@schemas = {}
          else
            ::RactorRailsShim.storage[:ractor_rails_shim_json_schemas] = {}
          end
        end

        def validators
          if ::Ractor.main?
            @@validators
          else
            snapshot = begin
              ::RactorRailsShim::JSON_VALIDATORS
            rescue ::NameError
              nil
            end
            snapshot || {}
          end
        end

        def default_validator
          if ::Ractor.main?
            @@default_validator
          else
            begin
              ::RactorRailsShim::JSON_DEFAULT_VALIDATOR
            rescue ::NameError
              nil
            end
          end
        end

        def json_backend
          if ::Ractor.main?
            @@json_backend
          else
            backend = begin
              ::RactorRailsShim::JSON_JSON_BACKEND
            rescue ::NameError
              nil
            end
            backend || 'json'
          end
        end

        def use_multi_json?
          if ::Ractor.main?
            @@use_multi_json
          else
            snapshot = begin
              ::RactorRailsShim::JSON_USE_MULTI_JSON
            rescue ::NameError
              nil
            end
            snapshot.nil? ? ::Object.const_defined?(:MultiJson) : snapshot
          end
        end

        def multi_json_deprecation_warning!
          if ::Ractor.main?
            unless @@multi_json_warned
              @@multi_json_warned = true
              warn '[DEPRECATION NOTICE] json-schema support for MultiJSON is deprecated and will be removed in a future version. ' \
                   "To stop using MultiJSON, add `JSON::Validator.use_multi_json = false` to your application's initialization code."
            end
          else
            key = :ractor_rails_shim_json_multi_json_warned
            unless ::RactorRailsShim.storage[key]
              warn '[DEPRECATION NOTICE] json-schema support for MultiJSON is deprecated and will be removed in a future version. ' \
                   "To stop using MultiJSON, add `JSON::Validator.use_multi_json = false` to your application's initialization code."
            end
            ::RactorRailsShim.storage[key] = true
          end
        end

        def parse(s)
          if use_multi_json?
            multi_json_deprecation_warning!
            begin
              ::MultiJson.respond_to?(:adapter) ? ::MultiJson.load(s) : ::MultiJson.decode(s)
            rescue MultiJson::ParseError => e
              raise ::JSON::Schema::JsonParseError, e.message
            end
          elsif ::Ractor.main?
            # Original body.
            case @@json_backend.to_s
            when 'json'
              begin
                JSON.parse(s)
              rescue JSON::ParserError => e
                raise ::JSON::Schema::JsonParseError, e.message
              end
            when 'yajl'
              begin
                json = ::StringIO.new(s)
                parser = ::Yajl::Parser.new
                parser.parse(json) or raise(JSON::Schema::JsonParseError, 'The JSON could not be parsed by yajl')
              rescue Yajl::ParseError => e
                raise ::JSON::Schema::JsonParseError, e.message
              end
            else
              raise JSON::Schema::JsonParseError, "No supported JSON parsers found. The following parsers are suported:\n * yajl-ruby\n * json"
            end
          else
            case json_backend.to_s
            when 'json'
              begin
                JSON.parse(s)
              rescue JSON::ParserError => e
                raise ::JSON::Schema::JsonParseError, e.message
              end
            else
              raise JSON::Schema::JsonParseError, "No supported JSON parsers found. The following parsers are suported:\n * yajl-ruby\n * json"
            end
          end
        end
      RUBY
    end

    # Worker-safe `initialize`: same structure as upstream, with the three
    # unshareable reads swapped for the per-Ractor paths above. `use_multi_json?`
    # (a shareable boolean) and the @validation_options block are unchanged.
    def _install_json_schema_initialize
      ::JSON::Validator.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def initialize(schema_data, opts = {})
          @options =
            if ::Ractor.main?
              @@default_opts.clone.merge(opts)
            else
              defaults = begin
                ::RactorRailsShim::JSON_DEFAULT_OPTS
              rescue ::NameError
                {}
              end
              defaults.dup.merge(opts)
            end

          configured_validator = self.class.validator_for_name(@options[:version])
          @options[:schema_reader] ||= self.class.schema_reader

          @validation_options = @options[:record_errors] ? { record_errors: true } : {}
          @validation_options[:insert_defaults] = true if @options[:insert_defaults]
          if @options[:strict] == true
            @validation_options[:allPropertiesRequired] = true
            @validation_options[:noAdditionalProperties] = true
          else
            @validation_options[:allPropertiesRequired] = true if @options[:allPropertiesRequired]
            @validation_options[:noAdditionalProperties] = true if @options[:noAdditionalProperties]
          end
          if ::Ractor.main?
            @validation_options[:clear_cache] = true if !@@cache_schemas || @options[:clear_cache]
          else
            # No cvar reads off-main (class variables are forbidden there
            # regardless of value); the boot-selected @@cache_schemas
            # default is true, matching upstream's unset path.
            @validation_options[:clear_cache] = true if @options[:clear_cache]
          end

          if ::Ractor.main?
            @@mutex.synchronize { @base_schema = initialize_schema(schema_data, configured_validator) }
            @@mutex.synchronize { build_schemas(@base_schema) }
          else
            @base_schema = initialize_schema(schema_data, configured_validator)
            build_schemas(@base_schema)
          end

          # validate the schema, if requested
          if @options[:validate_schema]
            # Don't clear the cache during metaschema validation!
            meta_validator = self.class.new(@base_schema.validator.metaschema, { clear_cache: false })
            meta_validator.validate(@base_schema.schema)
          end

          # If the :fragment option is set, try and validate against the fragment
          if opts[:fragment]
            @base_schema = schema_from_fragment(@base_schema, opts[:fragment])
          end
        end
      RUBY
    end

    # Worker-safe `serialize` / `fake_uuid`: rebuild the (stateless) lambdas
    # Ractor-locally instead of reading the Proc cvars. Main keeps upstream.
    def _install_json_schema_private_procs
      # `fake_uuid` uses the RFC4122 Nil UUID as the SHA-1 namespace. Upstream
      # leaves that Struct instance unfrozen, so the constant is unshareable;
      # freeze it in place on main so workers can read it.
      if ::Ractor.main? && defined?(::JSON::Util::UUID) && !::Ractor.shareable?(::JSON::Util::UUID::Nil)
        ::Ractor.make_shareable(::JSON::Util::UUID::Nil)
      end
      ::JSON::Validator.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def serialize(schema)
          if self.class.use_multi_json?
            self.class.multi_json_deprecation_warning!
            ::MultiJson.respond_to?(:dump) ? ::MultiJson.dump(schema) : ::MultiJson.encode(schema)
          elsif ::Ractor.main?
            @@serializer.call(schema)
          else
            ->(o) { ::JSON.dump(o) }.call(schema)
          end
        end

        def fake_uuid(schema)
          if ::Ractor.main?
            @@fake_uuid_generator.call(schema)
          elsif defined?(::UUIDTools::UUID)
            ->(s) { ::UUIDTools::UUID.sha1_create(::UUIDTools::UUID_URL_NAMESPACE, s).to_s }.call(schema)
          else
            ->(s) { ::JSON::Util::UUID.create_v5(s, ::JSON::Util::UUID::Nil).to_s }.call(schema)
          end
        end
      RUBY
    end
  end
end
