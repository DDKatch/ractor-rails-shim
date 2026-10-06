# frozen_string_literal: true

# Patches for Rack: Rack::Request class-level attr_accessors and
# Rack::Utils singleton attr_accessors.

module RactorRailsShim
  # Rack constants whose values are mutable and need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "Rack::Utils::PATH_SEPS",
    "Rack::Utils::HTTP_STATUS_CODES",
    "Rack::Utils::COMMON_SEP",
    "Rack::Utils::STATUS_WITH_NO_ENTITY_BODY",
    "Rack::Utils::SYMBOL_TO_STATUS_CODE",
    "Rack::MethodOverride::ALLOWED_METHODS",
    "Rack::MethodOverride::METHOD_OVERRIDES",
    "Rack::MethodOverride::HTTP_METHODS",
    "Rack::Headers::KNOWN_HEADERS",
    "Rack::Request::Helpers::FORM_DATA_MEDIA_TYPES",
    "Rack::Request::Helpers::PARSEABLE_DATA_MEDIA_TYPES",
    "Rack::Request::Helpers::DEFAULT_PORTS",
    "Rack::Mime::MIME_TYPES",
    "Rack::Files::ALLOWED_VERBS",
    "Rack::Files::ALLOW_HEADER",
    "Rack::Response::STATUS_WITH_NO_ENTITY_BODY",
    # Multipart file-upload parser constants, read by worker Ractors on every
    # POST (Rack::Request#POST -> parse_multipart -> Parser.parse). TEMPFILE_FACTORY
    # is a lambda; EMPTY is a MultipartInfo sentinel instance; REENCODE_DUMMY_
    # ENCODINGS is a mutable Hash. None are shareable by default.
    "Rack::Multipart::Parser::TEMPFILE_FACTORY",
    "Rack::Multipart::Parser::EMPTY",
      "Rack::Multipart::Parser::REENCODE_DUMMY_ENCODINGS",
  ])

  # Source-location constant used by make_app_shareable!'s proc-replacement
  # graph traversal (moved here from make_shareable.rb so the Rack concern's
  # pieces live together).
  FILES_LOC = "/rack/files.rb".freeze

  class << self
    # Patch Rack::Request's class-level attr_accessors (forwarded_priority,
    # x_forwarded_proto_priority) to not read @ivars from a worker Ractor.
    # The values are frozen-Symbol Arrays (shareable); route the cache
    # through IES with the same default in workers. Read per-request via
    # ActionDispatch::RemoteIp. Applied at prepare_for_ractors! time (after
    # Rails boots, so Rack is loaded).
    def _install_rack_request_patch
      return if @rack_request_patched
      @rack_request_patched = true
      _register_patch :rack_request, "8.1"
      return unless defined?(::Rack::Request)
      req = ::Rack::Request
      fp_key = :ractor_rails_shim_rack_forwarded_priority
      xp_key = :ractor_rails_shim_rack_x_forwarded_proto_priority
      fp_key_str = fp_key.inspect
      xp_key_str = xp_key.inspect
      req.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def forwarded_priority
          v = RactorRailsShim.storage[#{fp_key_str}]
          return v if RactorRailsShim.storage.key?(#{fp_key_str})
          if Ractor.main? && instance_variable_defined?(:@forwarded_priority)
            @forwarded_priority
          else
            [:forwarded, :x_forwarded]
          end
        end
        def forwarded_priority=(val)
          RactorRailsShim.storage[#{fp_key_str}] = val
          @forwarded_priority = val if Ractor.main?
          val
        end
        def x_forwarded_proto_priority
          v = RactorRailsShim.storage[#{xp_key_str}]
          return v if RactorRailsShim.storage.key?(#{xp_key_str})
          if Ractor.main? && instance_variable_defined?(:@x_forwarded_proto_priority)
            @x_forwarded_proto_priority
          else
            [:proto, :scheme]
          end
        end
        def x_forwarded_proto_priority=(val)
          RactorRailsShim.storage[#{xp_key_str}] = val
          @x_forwarded_proto_priority = val if Ractor.main?
          val
        end
      RUBY
    end

    # Patch Rack::Utils singleton attr_accessors (default_query_parser,
    # multipart_total_part_limit, multipart_file_limit) to not read @ivars
    # from a worker Ractor. The values are shareable once frozen (QueryParser,
    # Integers). Route through IES; workers read the shareable fallback.
    # `default_query_parser` is read per-request during POST parsing.
    def _install_rack_utils_patch
      return if @rack_utils_patched
      @rack_utils_patched = true
      _register_patch :rack_utils, "8.1"
      return unless defined?(::Rack::Utils)
      u = ::Rack::Utils
      dqp_key = :ractor_rails_shim_rack_utils_default_query_parser
      mtp_key = :ractor_rails_shim_rack_utils_multipart_total_part_limit
      mfl_key = :ractor_rails_shim_rack_utils_multipart_file_limit
      dqp_key_str = dqp_key.inspect
      mtp_key_str = mtp_key.inspect
      mfl_key_str = mfl_key.inspect
      u.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_query_parser
          v = RactorRailsShim.storage[#{dqp_key_str}]
          return v if RactorRailsShim.storage.key?(#{dqp_key_str})
          if Ractor.main? && instance_variable_defined?(:@default_query_parser)
            v = @default_query_parser
            RactorRailsShim.storage[#{dqp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{dqp_key_str}] || ::Rack::QueryParser::QueryParser.make_default(32)
          end
        end
        def multipart_total_part_limit
          v = RactorRailsShim.storage[#{mtp_key_str}]
          return v if RactorRailsShim.storage.key?(#{mtp_key_str})
          if Ractor.main? && instance_variable_defined?(:@multipart_total_part_limit)
            v = @multipart_total_part_limit
            RactorRailsShim.storage[#{mtp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{mtp_key_str}] || 128
          end
        end
        def multipart_file_limit
          v = RactorRailsShim.storage[#{mfl_key_str}]
          return v if RactorRailsShim.storage.key?(#{mfl_key_str})
          if Ractor.main? && instance_variable_defined?(:@multipart_file_limit)
            v = @multipart_file_limit
            RactorRailsShim.storage[#{mfl_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{mfl_key_str}] || 64
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["Rack::Utils", :default_query_parser, dqp_key, nil]
      CLASS_ATTRIBUTES << ["Rack::Utils", :multipart_total_part_limit, mtp_key, nil]
      CLASS_ATTRIBUTES << ["Rack::Utils", :multipart_file_limit, mfl_key, nil]
    end

    # Ruby's delegate.rb defines the `special` methods of every
    # DelegateClass(X) (Tempfile < DelegateClass(File) included) via
    # `define_method(method, Delegator.delegating_block(method))` — the body
    # is a lambda compiled in the main Ractor. Calling any of them from a
    # worker Ractor raises "defined with an un-shareable Proc in a different
    # Ractor". The bulk delegate methods are string-eval'd (shareable defs),
    # which is why `Tempfile#write` works from a worker while `Tempfile#<<`
    # explodes — observed on every multipart/form-data upload
    # (Rack::Multipart::Parser::Collector#on_mime_body appends to the
    # Tempfile with `<<`).
    #
    # Fix: at prepare time (classes still mutable), detect every method that
    # was defined from `Delegator.delegating_block`'s lambda — all such
    # methods share that lambda's exact source_location — and redefine them
    # as plain string-eval'd defs with identical semantics
    # (`target.__send__(mid, *args, &block)`). Detection is version-proof: the
    # marker location is resolved live from delegating_block itself.
    def _install_delegator_patch
      return if @delegator_patched
      @delegator_patched = true
      _register_patch :delegator, "8.1"
      return unless defined?(::Delegator) && defined?(::Tempfile)

      marker = ::Delegator.delegating_block(:"__rrs_marker__").source_location
      return unless marker.is_a?(::Array) && marker.size == 2
      marker_file = marker[0]
      marker_line = marker[1]

      require "objspace"
      ::ObjectSpace.each_object(::Class) do |klass|
        next unless (sc = klass.superclass) && sc.name.nil?
        (klass.instance_methods(false) + klass.protected_instance_methods(false) + klass.private_instance_methods(false)).each do |m|
          mm = (klass.instance_method(m) rescue nil)
          loc = mm&.source_location
          next unless loc.is_a?(::Array) && loc.size == 2 &&
                      loc[0] == marker_file && loc[1] == marker_line
          begin
            klass.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
              def #{m}(*args, &b)
                t = self.__getobj__
                t.__send__(#{m.inspect}, *args, &b)
              end
            RUBY
          rescue StandardError
            # frozen class or oddball method name — leave the original; the
            # worker call will fail loudly instead of silently.
          end
        end
      end
      true
    end

    # Find the Rack::Files (asset) server in the middleware chain, used by
    # make_app_shareable! when replacing the Rack::Head#@app lambda (whose
    # binding receiver is the Rack::Files instance). Moved here from
    # make_shareable.rb so the Rack concern's pieces live together.
    def _find_files_server(mw)
      cur = mw
      while cur
        if cur.class.name == "ActionDispatch::Static"
          return cur.instance_variable_get(:@file_server)
        end
        cur = cur.instance_variable_get(:@app) rescue nil
      end
      nil
    end
  end
end
