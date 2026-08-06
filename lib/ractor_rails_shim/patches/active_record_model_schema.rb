# frozen_string_literal: true

# ActiveRecord caches a number of values in class-level ivars via `@ivar ||=`
# (ModelSchema::ClassMethods). Several of these hold UNshareable values
# (AttributeSet::Builder, AttributeSet::YAMLEncoder, Hashes of Attribute
# objects) or take arguments, so neither pre-warming nor `Ractor.make_shareable`
# makes them safe for worker Ractors: a worker reading the class ivar hits
# Ractor::IsolationError (unshareable value) and writing it (the `||=`) hits
# "can not set instance variables of classes/modules by non-main Ractors".
#
# We redirect these specific caches to per-Ractor storage
# (RactorRailsShim.storage), keyed by the class. Each worker
# Ractor computes and keeps its OWN copy — it never touches the shared class
# ivar, so there is no cross-boundary (unshareable) value and no class-ivar
# write. The values are deterministic from the schema/connection, so per-Ractor
# caching is behavior-preserving. In the main Ractor this behaves identically
# (compute once, cache).

module RactorRailsShim
  module ActiveRecordModelSchemaPatch
    def self.prepended(base)
      base.prepend(InstanceMethods)
    end

    module InstanceMethods
      def _returning_columns_for_insert(connection) # :nodoc:
        key = :"rrs_returning_cols_#{object_id}"
        RactorRailsShim.storage[key] ||= begin
          auto_populated_columns = columns.filter_map do |c|
            c.name if connection.return_value_after_insert?(c)
          end

          auto_populated_columns.empty? ? Array(primary_key) : auto_populated_columns
        end
      end

      def attributes_builder # :nodoc:
        key = :"rrs_attributes_builder_#{object_id}"
        RactorRailsShim.storage[key] ||= begin
          defaults = _default_attributes.except(*(column_names - [primary_key]))
          ::ActiveModel::AttributeSet::Builder.new(attribute_types, defaults)
        end
      end

      def column_defaults # :nodoc:
        key = :"rrs_column_defaults_#{object_id}"
        RactorRailsShim.storage[key] ||=
          _default_attributes.deep_dup.to_hash.freeze
      end

      def yaml_encoder # :nodoc:
        key = :"rrs_yaml_encoder_#{object_id}"
        RactorRailsShim.storage[key] ||=
          ::ActiveModel::AttributeSet::YAMLEncoder.new(attribute_types)
      end

      # NOTE: `attribute_names` is NOT patched here — it is defined on
      # `ActiveRecord::AttributeMethods::ClassMethods`, which sits earlier in
      # the ancestor chain than this (ModelSchema) module, so a patch here
      # would be shadowed. It is patched directly on AttributeMethods in
      # `_install_active_record_model_schema_patch` (activerecord.rb).

      # `columns` / `column_names` / `symbol_column_to_string` /
      # `content_columns` / `attribute_names` all memoize via a class ivar
      # (`@columns`, `@column_names`, ...). Writing that ivar from a worker
      # Ractor raises "can not set instance variables of classes/modules by
      # non-main Ractors" — and kino's worker Ractors do not share main's
      # class-ivar space (unlike Ractor.new workers), so the `||=` can never
      # populate it. Route each cache through per-Ractor IES, keyed by the
      # class, mirroring the other ModelSchema patches above. Main keeps the
      # original class-ivar path.
      def columns
        if ::Ractor.main?
          @columns ||= columns_hash.values.freeze
        else
          key = :"rrs_columns_#{object_id}"
          RactorRailsShim.storage[key] ||= columns_hash.values.freeze
        end
      end

      def column_names
        if ::Ractor.main?
          @column_names ||= columns.map(&:name).freeze
        else
          key = :"rrs_column_names_#{object_id}"
          RactorRailsShim.storage[key] ||= columns.map(&:name).freeze
        end
      end

      def symbol_column_to_string(name_symbol) # :nodoc:
        if ::Ractor.main?
          @symbol_column_to_string_name_hash ||= column_names.index_by(&:to_sym)
          @symbol_column_to_string_name_hash[name_symbol]
        else
          key = :"rrs_symbol_col_#{object_id}"
          hash = RactorRailsShim.storage[key] ||= column_names.index_by(&:to_sym)
          hash[name_symbol]
        end
      end

      def content_columns
        if ::Ractor.main?
          @content_columns ||= columns.reject do |c|
            c.name == primary_key ||
              c.name == inheritance_column ||
              c.name.end_with?("_id", "_count")
          end.freeze
        else
          key = :"rrs_content_cols_#{object_id}"
          RactorRailsShim.storage[key] ||= columns.reject do |c|
            c.name == primary_key ||
              c.name == inheritance_column ||
              c.name.end_with?("_id", "_count")
          end.freeze
        end
      end
    end
  end
end
