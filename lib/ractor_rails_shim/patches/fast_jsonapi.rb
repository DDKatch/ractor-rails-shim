# frozen_string_literal: true

# Patch fast_jsonapi's per-serializer class metadata for worker Ractors.
#
# `FastJsonapi::SerializationCore`'s `included do` block defines TWELVE
# class-level attr_accessors on every serializer class
# (`attributes_to_serialize`, `relationships_to_serialize`, …,
# `lib/fast_jsonapi/serialization_core.rb:13-25`). The DSL writes Hashes of
# `Attribute`/`Relationship`/`Link` objects at boot — each holding a Proc —
# and the serialization path (`serialization_core.rb:45-121`) READS them per
# request. A worker reading a class ivar holding a mutable Hash raises
# IsolationError; even frozen, main-Ractor Procs inside the metadata can't be
# called from workers — UNLESS the Procs themselves are shareable (verified
# on Ruby 4.0.7: shareable Procs ARE callable from worker Ractors), which is
# the common case for `set_id { |record| record.uuid }`-style blocks (self =
# the serializer CLASS — a shareable module).
#
# Fix (capture-and-replay):
#   * Writer interception: every `*_to_serialize=`-family WRITE attempts
#     `::Ractor.make_shareable` on the value (Proc-containing graphs whose
#     Procs have shareable self/locals freeze cleanly) and stores the frozen
#     copy in a shareable registry keyed by the serializer class's
#     object_id. Un-shareable values (Procs capturing non-shareable state)
#     are omitted from the registry with a funnel-logged note.
#   * Reader interception: main keeps the live ivars byte-for-byte; workers
#     read the frozen capture (missing keys => nil — the same shape an
#     unset serializer has, degrading instead of crashing).
#   * Subclass copies made by the `inherited` hook (`subclass.x =
#     attributes_to_serialize.dup`) go through the same intercepted
#     writers, so inherited serializers capture too.
#
# Serializer classes are enumerated via ObjectSpace at install (they are
# app-defined, so there is no registry to walk).

module RactorRailsShim
  class << self
    FAST_JSONAPI_ATTRS = %i[
      attributes_to_serialize relationships_to_serialize
      cachable_relationships_to_serialize uncachable_relationships_to_serialize
      transform_method record_type record_id cache_length
      race_condition_ttl cached data_links meta_to_serialize
    ].freeze

    def _install_fast_jsonapi_patch
      return if @fast_jsonapi_patched
      @fast_jsonapi_patched = true
      _register_patch :fast_jsonapi, "8.1"
      return unless defined?(::FastJsonapi::ObjectSerializer)

      return unless ::Ractor.main?
      registry = {}
      fast_jsonapi_serializer_classes.each do |klass|
        entries = {}
        FAST_JSONAPI_ATTRS.each do |attr|
          next unless klass.instance_variable_defined?("@#{attr}")
          value = klass.instance_variable_get("@#{attr}")
          next if value.nil?
          begin
            entries[attr] = ::Ractor.make_shareable(value)
          rescue ::StandardError
            ::RactorRailsShim::Funnel.swallow("fast_jsonapi #{klass}##{attr} unshareable") { raise }
          end
        end
        registry[klass.object_id] = ::Ractor.make_shareable(entries) unless entries.empty?
        _install_fast_jsonapi_accessors(klass)
      end
      _reassign_shareable_const(:FAST_JSONAPI_TABLES, ::Ractor.make_shareable(registry))
    end

    private

    def fast_jsonapi_serializer_classes
      serializers = []
      begin
        ObjectSpace.each_object(::Class) do |klass|
          serializers << klass if klass < ::FastJsonapi::ObjectSerializer
        end
      rescue ::StandardError
        serializers = []
      end
      serializers << ::FastJsonapi::ObjectSerializer
      serializers
    end

    # Route the class accessors through the captured registry: main keeps
    # the live ivars; workers read the frozen capture.
    def _install_fast_jsonapi_accessors(klass)
      FAST_JSONAPI_ATTRS.each do |attr|
        klass.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_shim_original_#{attr}, :#{attr}
          def #{attr}
            if ::Ractor.main?
              instance_variable_defined?(:@#{attr}) ? instance_variable_get(:@#{attr}) : nil
            else
              entry = ::RactorRailsShim::FAST_JSONAPI_TABLES[object_id]
              entry && entry[:#{attr}]
            end
          end

          alias_method :_shim_original_#{attr}_set, :#{attr}=
          def #{attr}=(value)
            if ::Ractor.main?
              instance_variable_set(:@#{attr}, value)
              ::RactorRailsShim._capture_fast_jsonapi_attr(self, :#{attr}, value)
            end
            value
          end
        RUBY
      end
    end

    def _capture_fast_jsonapi_attr(klass, attr, value)
      return if value.nil?
      shareable = ::Ractor.make_shareable(value) rescue nil
      unless shareable
        ::RactorRailsShim::Funnel.swallow("fast_jsonapi #{klass}##{attr} unshareable") { raise }
        return
      end
      registry = (::RactorRailsShim.singleton_class.const_get(:FAST_JSONAPI_TABLES).dup rescue nil) || {}
      entry = (registry[klass.object_id] || {}).dup
      entry[attr] = shareable
      registry[klass.object_id] = ::Ractor.make_shareable(entry)
      _reassign_shareable_const(:FAST_JSONAPI_TABLES, ::Ractor.make_shareable(registry))
    end
  end
end
